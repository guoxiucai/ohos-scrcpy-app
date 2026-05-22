use anyhow::{Context, Result};
use sdl2::event::Event;
use sdl2::mouse::MouseButton;
use sdl2::pixels::PixelFormatEnum;
use sdl2::rect::Rect;
use sdl2::render::{Canvas, Texture, TextureCreator};
use sdl2::video::{Window, WindowContext};
use std::time::Instant;

use crate::decoder::DecodedFrame;
use super::AppEvent;

pub struct SdlRenderer {
    // 析构顺序：texture 先析构，canvas 最后（保证 SDL_Renderer 在纹理释放后才销毁）
    texture: Option<Texture>,
    texture_creator: TextureCreator<WindowContext>,
    canvas: Canvas<Window>,
    video_w: u32,
    video_h: u32,
    frame_count: u32,
    fps_timer: Instant,
    device_serial: String,
}

impl SdlRenderer {
    pub fn new(title: &str, init_w: u32, init_h: u32) -> Result<(Self, sdl2::EventPump)> {
        let sdl = sdl2::init().map_err(|e| anyhow::anyhow!("SDL2 init: {}", e))?;
        let video = sdl.video().map_err(|e| anyhow::anyhow!("SDL2 video: {}", e))?;
        let event_pump = sdl.event_pump().map_err(|e| anyhow::anyhow!("SDL2 events: {}", e))?;

        let window = video
            .window(title, init_w.max(1), init_h.max(1))
            .resizable()
            .position_centered()
            .build()
            .context("SDL2 window build")?;

        let canvas = window
            .into_canvas()
            .accelerated()
            // present_vsync 会在每帧 canvas.present() 时阻塞约 16ms，
            // 导致 macOS 合并 MouseMove 事件，大量 TouchMove 丢失。
            // 去掉 vsync，由服务端帧率自然限速（20fps），保证事件及时上报。
            .build()
            .context("SDL2 canvas build")?;

        let texture_creator = canvas.texture_creator();

        Ok((
            SdlRenderer {
                texture: None,
                texture_creator,
                canvas,
                video_w: 0,
                video_h: 0,
                frame_count: 0,
                fps_timer: Instant::now(),
                device_serial: title.to_string(),
            },
            event_pump,
        ))
    }

    /// 渲染一帧 I420 数据到窗口
    pub fn present_frame(&mut self, frame: &DecodedFrame) -> Result<()> {
        if self.texture.is_none()
            || frame.width != self.video_w
            || frame.height != self.video_h
        {
            self.video_w = frame.width;
            self.video_h = frame.height;
            let tex = self.texture_creator
                .create_texture_streaming(PixelFormatEnum::IYUV, frame.width, frame.height)
                .map_err(|e| anyhow::anyhow!("create texture: {}", e))?;
            self.texture = Some(tex);
        }

        // 先计算目标矩形（需要不可变借用 self），再借用 texture（可变借用）
        let dst = self.compute_dst_rect();

        let tex = self.texture.as_mut().unwrap();
        let y_pitch = frame.width as usize;
        let uv_pitch = frame.width as usize / 2;
        tex.update_yuv(
            None,
            &frame.y_plane, y_pitch,
            &frame.u_plane, uv_pitch,
            &frame.v_plane, uv_pitch,
        ).map_err(|e| anyhow::anyhow!("update YUV texture: {}", e))?;

        self.canvas.clear();
        self.canvas.copy(tex, None, dst)
            .map_err(|e| anyhow::anyhow!("canvas copy: {}", e))?;
        self.canvas.present();

        // FPS counter → window title
        self.frame_count += 1;
        let elapsed = self.fps_timer.elapsed().as_secs_f32();
        if elapsed >= 1.0 {
            let fps = self.frame_count as f32 / elapsed;
            let title = format!("ohscrcpy | {} | {:.0}fps", self.device_serial, fps);
            self.canvas.window_mut().set_title(&title).ok();
            self.frame_count = 0;
            self.fps_timer = Instant::now();
        }
        Ok(())
    }

    fn compute_dst_rect(&self) -> Rect {
        let (win_w, win_h) = self.canvas.window().size();
        if self.video_w == 0 || self.video_h == 0 {
            return Rect::new(0, 0, win_w, win_h);
        }
        let scale = (win_w as f32 / self.video_w as f32)
            .min(win_h as f32 / self.video_h as f32);
        let out_w = (self.video_w as f32 * scale) as u32;
        let out_h = (self.video_h as f32 * scale) as u32;
        Rect::new(
            ((win_w - out_w) / 2) as i32,
            ((win_h - out_h) / 2) as i32,
            out_w, out_h,
        )
    }

    /// 将窗口坐标归一化到视频区域 [0.0, 1.0]
    pub fn normalize(&self, px: i32, py: i32) -> (f32, f32) {
        let dst = self.compute_dst_rect();
        let x = ((px - dst.x()) as f32 / dst.width() as f32).clamp(0.0, 1.0);
        let y = ((py - dst.y()) as f32 / dst.height() as f32).clamp(0.0, 1.0);
        (x, y)
    }
}

/// 轮询 SDL2 事件，转换为 AppEvent
pub fn poll_events(event_pump: &mut sdl2::EventPump, renderer: &SdlRenderer) -> Vec<AppEvent> {
    let mut events = Vec::new();
    for ev in event_pump.poll_iter() {
        match ev {
            Event::Quit { .. } => {
                events.push(AppEvent::Quit);
            }
            Event::MouseButtonDown { x, y, mouse_btn: MouseButton::Left, .. } => {
                let (xn, yn) = renderer.normalize(x, y);
                events.push(AppEvent::TouchDown { x_norm: xn, y_norm: yn });
            }
            Event::MouseMotion { x, y, mousestate, .. } if mousestate.left() => {
                let (xn, yn) = renderer.normalize(x, y);
                events.push(AppEvent::TouchMove { x_norm: xn, y_norm: yn });
            }
            Event::MouseButtonUp { x, y, mouse_btn: MouseButton::Left, .. } => {
                let (xn, yn) = renderer.normalize(x, y);
                events.push(AppEvent::TouchUp { x_norm: xn, y_norm: yn });
            }
            Event::MouseButtonDown { mouse_btn: MouseButton::Right, .. } => {
                events.push(AppEvent::KeyBack);
            }
            Event::Window {
                win_event: sdl2::event::WindowEvent::Resized(w, h), ..
            } => {
                events.push(AppEvent::WindowResized { width: w as u32, height: h as u32 });
            }
            _ => {}
        }
    }
    events
}
