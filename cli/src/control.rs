use byteorder::{BigEndian, WriteBytesExt};

/// 控制子类型，对应协议 0x10 帧的 subType 字节
#[repr(u8)]
#[derive(Debug, Clone, Copy)]
pub enum ControlSubType {
    TouchDown = 0x01,
    TouchMove = 0x02,
    TouchUp   = 0x03,
    KeyBack   = 0x10,
}

/// 编码触摸按下事件（设备像素坐标，uint32 BE）
pub fn encode_touch_down(x: u32, y: u32, pointer_id: u16) -> Vec<u8> {
    encode_touch(ControlSubType::TouchDown, x, y, pointer_id)
}

/// 编码触摸移动事件（设备像素坐标，uint32 BE）
pub fn encode_touch_move(x: u32, y: u32, pointer_id: u16) -> Vec<u8> {
    encode_touch(ControlSubType::TouchMove, x, y, pointer_id)
}

/// 编码触摸抬起事件（设备像素坐标，uint32 BE）
pub fn encode_touch_up(x: u32, y: u32, pointer_id: u16) -> Vec<u8> {
    encode_touch(ControlSubType::TouchUp, x, y, pointer_id)
}

/// 编码返回键事件（backKey subType=0x13，与 Flutter 对齐）
pub fn encode_key_back() -> Vec<u8> {
    vec![0x13u8] // subType: BACK_KEY，body 为空
}

/// 编码视频参数配置（changeVideoParams, subType=0x42）
/// body: maxShort(4 BE) + bitrate(4 BE) + frameRate(4 BE)
pub fn encode_video_params(max_short: u32, bitrate: u32, frame_rate: u32) -> Vec<u8> {
    let mut buf = Vec::with_capacity(1 + 12);
    buf.push(0x42u8); // subType: CHANGE_VIDEO_PARAMS
    buf.write_u32::<BigEndian>(max_short).unwrap();
    buf.write_u32::<BigEndian>(bitrate).unwrap();
    buf.write_u32::<BigEndian>(frame_rate).unwrap();
    buf
}

/// 协议格式: subType(1) + x(4 BE uint32) + y(4 BE uint32) + pointerId(2 BE uint16) = 11 bytes
fn encode_touch(sub_type: ControlSubType, x: u32, y: u32, pointer_id: u16) -> Vec<u8> {
    let mut buf = Vec::with_capacity(1 + 4 + 4 + 2);
    buf.push(sub_type as u8);
    buf.write_u32::<BigEndian>(x).unwrap();
    buf.write_u32::<BigEndian>(y).unwrap();
    buf.write_u16::<BigEndian>(pointer_id).unwrap();
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_touch_down_size() {
        let b = encode_touch_down(100, 200, 0);
        assert_eq!(b.len(), 11);
        assert_eq!(b[0], 0x01);
        // x = 100 = 0x00000064
        assert_eq!(&b[1..5], &[0x00, 0x00, 0x00, 0x64]);
        // y = 200 = 0x000000C8
        assert_eq!(&b[5..9], &[0x00, 0x00, 0x00, 0xC8]);
    }

    #[test]
    fn test_encode_key_back() {
        let b = encode_key_back();
        assert_eq!(b[0], 0x13);
    }
}
