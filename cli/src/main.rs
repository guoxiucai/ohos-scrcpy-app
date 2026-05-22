mod args;
mod hdc;
mod server;
mod connection;
mod control;
mod decoder;
mod renderer;

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use std::io::{BufReader, BufWriter, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::sync_channel;
use std::sync::Arc;
use std::time::Duration;
use tracing::debug;

use args::Args;
use connection::{parse_video_config, parse_video_frame, read_frame, write_frame, FrameType};
use control::{encode_key_back, encode_touch_down, encode_touch_move, encode_touch_up, encode_video_params};
use decoder::vtb::VtbDecoder;
use renderer::{sdl, AppEvent};

fn main() {
    if let Err(e) = run() {
        eprintln!("error: {}", e);
        std::process::exit(exit_code(&e));
    }
}

fn run() -> Result<()> {
    let args = Args::parse();
    init_logging(args.verbose);

    // ── 1. hdc 检测 ──────────────────────────────────────────
    if args.verbose { eprintln!("[ohscrcpy] detecting devices..."); }
    let hdc_path = hdc::find_hdc().map_err(|e| tag(e, 7))?;
    debug!("hdc: {:?}", hdc_path);

    // ── 2. 设备选择 ──────────────────────────────────────────
    let devices = hdc::list_devices(&hdc_path).map_err(|e| tag(e, 2))?;
    let sn = match (&args.serial, devices.len()) {
        (Some(s), _) => {
            if !devices.contains(s) {
                return Err(tagged(anyhow!("device '{}' not found. Available:\n{}",
                    s, fmt_device_list(&devices)), 2));
            }
            s.clone()
        }
        (None, 0) => return Err(tagged(anyhow!(
            "no OpenHarmony devices found. Connect a device via USB and retry."), 2)),
        (None, 1) => devices[0].clone(),
        (None, _) => return Err(tagged(anyhow!(
            "multiple devices detected. Specify target with -s <serial>:\n{}",
            fmt_device_list(&devices)), 3)),
    };
    if args.verbose { eprintln!("[ohscrcpy] selected device: {}", sn); }

    // ── 3. 服务端确认/安装 ───────────────────────────────────
    server::ensure_server(&hdc_path, &sn, args.verbose).map_err(|e| tag(e, 4))?;
    server::start_server_and_wait(&hdc_path, &sn, args.verbose).map_err(|e| tag(e, 4))?;

    // ── 4. 端口转发 ──────────────────────────────────────────
    let pc_port = hdc::find_free_port(&hdc_path, &sn).map_err(|e| tag(e, 5))?;
    hdc::fport_add(&hdc_path, &sn, pc_port).map_err(|e| tag(e, 5))?;
    let _fport_guard = FportGuard { hdc: hdc_path.clone(), sn: sn.clone(), port: pc_port };
    if args.verbose {
        eprintln!("[ohscrcpy] setting up port forward: localhost:{} -> device:53535", pc_port);
    }

    let shutdown = Arc::new(AtomicBool::new(false));
    {
        let shutdown_c = shutdown.clone();
        ctrlc::set_handler(move || { shutdown_c.store(true, Ordering::SeqCst); }).ok();
    }

    // ── 5. TCP 连接 ──────────────────────────────────────────
    if args.verbose { eprintln!("[ohscrcpy] connecting to localhost:{}...", pc_port); }
    let stream = TcpStream::connect(format!("127.0.0.1:{}", pc_port))
        .with_context(|| format!("connecting to localhost:{}", pc_port))
        .map_err(|e| tag(e, 6))?;
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;

    let write_stream = stream.try_clone().context("clone TCP stream")?;
    let mut reader = BufReader::new(stream);
    let mut writer = BufWriter::new(write_stream);

    // 连接后立即发送视频参数（触发 restartCapture）
    // --max-size 0（默认）→ maxShort=32767（不限制），服务端以物理分辨率采集，浮窗位置正确
    // --max-size N → 强制 N 像素短边
    {
        let max_short = if args.max_size > 0 { args.max_size } else { 32767u32 };
        let bitrate = args.bit_rate as u32;
        let fps = args.fps;
        let params = encode_video_params(max_short, bitrate, fps);
        write_frame(&mut writer, 0x10, &params).map_err(|e| tag(e, 6))?;
        writer.flush().map_err(|e| tag(e.into(), 6))?;
        if args.verbose {
            eprintln!("[ohscrcpy] sent changeVideoParams: maxShort={} bitrate={}bps fps={}", max_short, bitrate, fps);
        }
    }

    // ── 6. 等待首个 VideoConfig ──────────────────────────────
    if args.verbose { eprintln!("[ohscrcpy] connected, waiting for video config..."); }
    let first_config = {
        let deadline = std::time::Instant::now() + Duration::from_secs(60);
        loop {
            if std::time::Instant::now() > deadline {
                return Err(tagged(anyhow!("timed out (60s) waiting for video config"), 6));
            }
            let (ft, payload) = read_frame(&mut reader).map_err(|e| tag(e, 6))?;
            if ft == FrameType::VideoConfig as u8 {
                break parse_video_config(&payload).map_err(|e| tag(e, 6))?;
            }
        }
    };
    if first_config.codec != 0 {
        return Err(tagged(anyhow!("only H264 codec is supported (got codec={})", first_config.codec), 6));
    }
    if args.verbose {
        eprintln!("[ohscrcpy] video config: H264 {}x{} @ {}fps, SPS({}B) PPS({}B)",
            first_config.width, first_config.height, first_config.fps,
            first_config.sps.len(), first_config.pps.len());
    }

    // 初始解码器
    let initial_decoder = VtbDecoder::new(&first_config.sps, &first_config.pps)
        .context("creating VTB decoder")?;

    // 共享当前视频分辨率（读取线程写入，主线程读取用于触控坐标换算）
    let dev_w = Arc::new(AtomicU32::new(first_config.width));
    let dev_h = Arc::new(AtomicU32::new(first_config.height));

    // ── 7. SDL2 窗口 ─────────────────────────────────────────
    let win_title = format!("ohscrcpy | {}", sn);
    let (win_w, win_h) = if args.max_size > 0 {
        scale_to_max(first_config.width, first_config.height, args.max_size)
    } else {
        let w = first_config.width.min(1280);
        let h = (first_config.height as f32 * w as f32 / first_config.width as f32) as u32;
        (w, h)
    };
    let (mut renderer, mut event_pump) =
        sdl::SdlRenderer::new(&win_title, win_w, win_h).context("SDL2 init")?;

    // ── 8. 通道设置 ──────────────────────────────────────────
    let (frame_tx, frame_rx) = sync_channel(4);
    let (ctrl_tx, ctrl_rx) = std::sync::mpsc::channel::<Vec<u8>>();

    // ── 9. 读取线程（动态处理 VideoConfig 变化）─────────────
    let shutdown_net = shutdown.clone();
    let dev_w_net = dev_w.clone();
    let dev_h_net = dev_h.clone();
    let verbose_net = args.verbose;
    std::thread::spawn(move || {
        let mut cur_decoder: Option<VtbDecoder> = Some(initial_decoder);
        let mut bytes_window = 0usize;
        let mut frame_count = 0u32;
        let mut window_start = std::time::Instant::now();

        loop {
            if shutdown_net.load(Ordering::SeqCst) { break; }
            match read_frame(&mut reader) {
                Ok((ft, payload)) => {
                    bytes_window += payload.len() + 8;

                    if ft == FrameType::VideoConfig as u8 {
                        // 动态分辨率变化（服务端 restartCapture 等）
                        if let Ok(cfg) = parse_video_config(&payload) {
                            dev_w_net.store(cfg.width, Ordering::Relaxed);
                            dev_h_net.store(cfg.height, Ordering::Relaxed);
                            if cfg.codec == 0 {
                                cur_decoder = VtbDecoder::new(&cfg.sps, &cfg.pps).ok();
                                if verbose_net {
                                    eprintln!("[ohscrcpy] video config changed: H264 {}x{} @ {}fps",
                                        cfg.width, cfg.height, cfg.fps);
                                }
                            } else {
                                cur_decoder = None;
                                if verbose_net {
                                    eprintln!("[ohscrcpy] unsupported codec {} — no video", cfg.codec);
                                }
                            }
                        }
                    } else if ft == FrameType::VideoFrame as u8 {
                        frame_count += 1;
                        if let Some(ref dec) = cur_decoder {
                            if let Ok(vf) = parse_video_frame(&payload) {
                                match dec.decode_frame(&vf.data) {
                                    Ok(decoded) => { frame_tx.send(decoded).ok(); }
                                    Err(e) => {
                                        if verbose_net { eprintln!("[ohscrcpy] decode error: {}", e); }
                                    }
                                }
                            }
                        }
                    }

                    if verbose_net {
                        let elapsed = window_start.elapsed().as_secs_f32();
                        if elapsed >= 1.0 {
                            let fps = frame_count as f32 / elapsed;
                            let mbps = (bytes_window as f32 * 8.0) / (elapsed * 1_000_000.0);
                            eprintln!("[ohscrcpy] fps={:.0} bitrate={:.1}Mbps", fps, mbps);
                            bytes_window = 0; frame_count = 0;
                            window_start = std::time::Instant::now();
                        }
                    }
                }
                Err(_) => {
                    if !shutdown_net.load(Ordering::SeqCst) {
                        eprintln!("[ohscrcpy] connection lost");
                        shutdown_net.store(true, Ordering::SeqCst);
                    }
                    break;
                }
            }
        }
    });

    // ── 10. 写入线程（控制指令 + 心跳）──────────────────────
    // 批量写入：攒满当前队列所有事件后一次 flush，减少 TCP 包数量
    let shutdown_write = shutdown.clone();
    std::thread::spawn(move || {
        let heartbeat_interval = Duration::from_secs(5);
        let mut last_heartbeat = std::time::Instant::now();
        loop {
            // 等待第一个事件（10ms 超时）
            let first = match ctrl_rx.recv_timeout(Duration::from_millis(10)) {
                Ok(p) => p,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    if shutdown_write.load(Ordering::SeqCst) { break; }
                    if last_heartbeat.elapsed() >= heartbeat_interval {
                        if write_frame(&mut writer, 0x01, &[]).is_err() { break; }
                        writer.flush().ok();
                        last_heartbeat = std::time::Instant::now();
                    }
                    continue;
                }
                Err(_) => break,
            };
            if write_frame(&mut writer, 0x10, &first).is_err() { break; }
            // 排空队列中所有待发事件（批量写入，尤其对高频 TouchMove 有效）
            while let Ok(payload) = ctrl_rx.try_recv() {
                if write_frame(&mut writer, 0x10, &payload).is_err() { break; }
            }
            // 整批一次 flush
            writer.flush().ok();
            last_heartbeat = std::time::Instant::now();
        }
    });

    // ── 11. SDL2 主事件循环 ──────────────────────────────────
    if args.verbose { eprintln!("[ohscrcpy] streaming started"); }
    loop {
        // 事件处理优先（TouchMove 高频，不能被渲染阻塞）
        let cur_dev_w = dev_w.load(Ordering::Relaxed);
        let cur_dev_h = dev_h.load(Ordering::Relaxed);
        for event in sdl::poll_events(&mut event_pump, &renderer) {
            match event {
                AppEvent::Quit => { shutdown.store(true, Ordering::SeqCst); }
                AppEvent::TouchDown { x_norm, y_norm } => {
                    let x = (x_norm * cur_dev_w as f32) as u32;
                    let y = (y_norm * cur_dev_h as f32) as u32;
                    ctrl_tx.send(encode_touch_down(x, y, 0)).ok();
                }
                AppEvent::TouchMove { x_norm, y_norm } => {
                    let x = (x_norm * cur_dev_w as f32) as u32;
                    let y = (y_norm * cur_dev_h as f32) as u32;
                    ctrl_tx.send(encode_touch_move(x, y, 0)).ok();
                }
                AppEvent::TouchUp { x_norm, y_norm } => {
                    let x = (x_norm * cur_dev_w as f32) as u32;
                    let y = (y_norm * cur_dev_h as f32) as u32;
                    ctrl_tx.send(encode_touch_up(x, y, 0)).ok();
                }
                AppEvent::KeyBack => { ctrl_tx.send(encode_key_back()).ok(); }
                AppEvent::WindowResized { .. } => {}
            }
        }

        // 渲染一帧（非阻塞，已移除 vsync）
        if let Ok(frame) = frame_rx.try_recv() {
            renderer.present_frame(&frame).ok();
        }

        if shutdown.load(Ordering::SeqCst) { break; }
        std::thread::sleep(Duration::from_millis(1)); // 1ms：确保高频 TouchMove 及时响应
    }

    Ok(())
}

fn init_logging(verbose: bool) {
    use tracing_subscriber::{fmt, EnvFilter};
    let filter = if verbose { "ohscrcpy=debug" } else { "ohscrcpy=warn" };
    fmt().with_env_filter(EnvFilter::new(filter)).with_writer(std::io::stderr).without_time().init();
}

fn fmt_device_list(devices: &[String]) -> String {
    devices.iter().map(|s| format!("  {}", s)).collect::<Vec<_>>().join("\n")
}

fn scale_to_max(w: u32, h: u32, max: u32) -> (u32, u32) {
    if w <= max && h <= max { return (w, h); }
    if w >= h { (max, (h as f32 * max as f32 / w as f32) as u32) }
    else { ((w as f32 * max as f32 / h as f32) as u32, max) }
}

struct FportGuard { hdc: std::path::PathBuf, sn: String, port: u16 }
impl Drop for FportGuard {
    fn drop(&mut self) { hdc::fport_rm(&self.hdc, &self.sn, self.port).ok(); }
}

struct Tagged { inner: anyhow::Error, code: i32 }
impl std::fmt::Display for Tagged {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { write!(f, "{}", self.inner) }
}
impl std::fmt::Debug for Tagged {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { write!(f, "{:?}", self.inner) }
}
impl std::error::Error for Tagged {}
fn tag(e: anyhow::Error, code: i32) -> anyhow::Error { anyhow::Error::new(Tagged { inner: e, code }) }
fn tagged(e: anyhow::Error, code: i32) -> anyhow::Error { tag(e, code) }
fn exit_code(e: &anyhow::Error) -> i32 { e.downcast_ref::<Tagged>().map(|t| t.code).unwrap_or(1) }
