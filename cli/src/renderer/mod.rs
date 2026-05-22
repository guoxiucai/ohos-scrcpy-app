/// SDL2 事件转换后的应用事件
#[derive(Debug, Clone)]
pub enum AppEvent {
    TouchDown { x_norm: f32, y_norm: f32 },
    TouchMove { x_norm: f32, y_norm: f32 },
    TouchUp   { x_norm: f32, y_norm: f32 },
    KeyBack,
    Quit,
    WindowResized { width: u32, height: u32 },
}

pub mod sdl;
