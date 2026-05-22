use clap::Parser;

/// OpenHarmony 设备屏幕镜像工具（ohscrcpy）
#[derive(Parser, Debug, Clone)]
#[command(name = "ohscrcpy", version, about = "OpenHarmony device screen mirroring tool")]
pub struct Args {
    /// 目标设备序列号（多设备时必须指定）
    #[arg(short = 's', long = "serial", value_name = "SERIAL")]
    pub serial: Option<String>,

    /// 投屏画面最大边长（像素），0 表示不限制
    #[arg(short = 'm', long = "max-size", value_name = "PX", default_value = "0")]
    pub max_size: u32,

    /// 视频流目标码率，支持 K/M 后缀（如 4M、2000K）
    #[arg(short = 'b', long = "bit-rate", value_name = "RATE", default_value = "8M",
          value_parser = parse_bit_rate)]
    pub bit_rate: u64,

    /// 目标帧率
    #[arg(long = "fps", value_name = "FPS", default_value = "60")]
    pub fps: u32,

    /// 启用详细日志输出到 stderr
    #[arg(short = 'v', long = "verbose")]
    pub verbose: bool,
}

fn parse_bit_rate(s: &str) -> Result<u64, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("empty bit rate".to_string());
    }
    let (digits, mult) = if s.ends_with('M') || s.ends_with('m') {
        (&s[..s.len() - 1], 1_000_000u64)
    } else if s.ends_with('K') || s.ends_with('k') {
        (&s[..s.len() - 1], 1_000u64)
    } else {
        (s, 1u64)
    };
    digits
        .parse::<u64>()
        .map(|n| n * mult)
        .map_err(|e| format!("invalid bit rate '{}': {}", s, e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_bit_rate() {
        assert_eq!(parse_bit_rate("8M").unwrap(), 8_000_000);
        assert_eq!(parse_bit_rate("2M").unwrap(), 2_000_000);
        assert_eq!(parse_bit_rate("500K").unwrap(), 500_000);
        assert_eq!(parse_bit_rate("1000000").unwrap(), 1_000_000);
        assert!(parse_bit_rate("").is_err());
        assert!(parse_bit_rate("abc").is_err());
    }
}
