use anyhow::{anyhow, Context, Result};
use std::io::Write as _;
use std::path::PathBuf;
use std::process::Command;
use tracing::{debug, info};

use crate::hdc;
// bundleName 和当前内置版本
const BUNDLE_NAME: &str = "com.ohos.scrcpy.server";
const BUNDLED_VERSION: u32 = 1;

#[derive(rust_embed::RustEmbed)]
#[folder = "assets/"]
struct Assets;

/// 检查设备上服务端的版本号（None = 未安装）
pub fn check_server_version(hdc_path: &PathBuf, sn: &str) -> Result<Option<u32>> {
    let out = hdc::shell(hdc_path, sn, &format!("bm dump -n {}", BUNDLE_NAME))?;
    // bm dump 未安装时输出含 "error" 或不包含 bundle 名
    if out.is_empty() || !out.contains(BUNDLE_NAME) {
        return Ok(None);
    }
    // 在整个输出中用 rfind 找最后一个 "versionCode": 并解析其数值
    // (避免 \r\n 行分割问题，取包级别 versionCode = 1000000)
    if let Some(idx) = out.rfind("\"versionCode\":") {
        let rest = &out[idx + "\"versionCode\":".len()..];
        let digits: String = rest.trim_start().chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(v) = digits.parse::<u32>() {
            if v > 0 {
                return Ok(Some(v));
            }
        }
    }
    // bundle 存在但无法解析 versionCode
    Ok(Some(BUNDLED_VERSION))
}

/// 安装内置 HAP 到目标设备
pub fn install_server(hdc_path: &PathBuf, sn: &str) -> Result<()> {
    let hap_data = Assets::get("scrcpy_server.hap")
        .ok_or_else(|| anyhow!("内置 scrcpy_server.hap 未找到，请重新构建"))?;

    // 写到临时文件
    let tmp = tempfile::Builder::new()
        .prefix("ohscrcpy_server_")
        .suffix(".hap")
        .tempfile()
        .context("创建 HAP 临时文件失败")?;
    // &File implements Write; use let mut to allow &mut &File for write_all
    let mut file_ref = tmp.as_file();
    file_ref.write_all(&hap_data.data)
        .context("写入 HAP 临时文件失败")?;
    let tmp_path = tmp.path().to_path_buf();

    info!("installing server HAP from {:?}", tmp_path);

    let output = Command::new(hdc_path)
        .args(["-t", sn, "install", "-r", tmp_path.to_str().unwrap()])
        .output()
        .context("hdc install 失败")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    debug!("install stdout: {}", stdout);
    debug!("install stderr: {}", stderr);

    if !output.status.success() || stdout.contains("Failure") || stderr.contains("error") {
        return Err(anyhow!(
            "failed to install scrcpy server: {}\n  \
             To install manually: hap is at {:?}",
            stdout.trim(),
            tmp_path,
        ));
    }
    Ok(())
}

/// 确保服务端已安装（版本不足时自动安装）
pub fn ensure_server(hdc_path: &PathBuf, sn: &str, verbose: bool) -> Result<()> {
    if verbose {
        eprintln!("[ohscrcpy] checking server version on device...");
    }
    match check_server_version(hdc_path, sn)? {
        Some(v) if v >= BUNDLED_VERSION => {
            debug!("server v{} already installed", v);
            if verbose {
                eprintln!("[ohscrcpy] server v{} already installed", v);
            }
        }
        installed => {
            if verbose {
                match installed {
                    None => eprintln!("[ohscrcpy] server not installed, installing bundled v{}...", BUNDLED_VERSION),
                    Some(v) => eprintln!("[ohscrcpy] server v{} outdated, upgrading to v{}...", v, BUNDLED_VERSION),
                }
            }
            install_server(hdc_path, sn)?;
            if verbose {
                eprintln!("[ohscrcpy] server installed successfully");
            }
        }
    }
    Ok(())
}

/// 启动服务并等待端口 53535 就绪（最多等 15 秒），同时清理遗留的 fport 规则
pub fn start_server_and_wait(hdc_path: &PathBuf, sn: &str, verbose: bool) -> Result<()> {
    if verbose { eprintln!("[ohscrcpy] starting ScrcpyService..."); }

    // 清理该设备上的旧 fport 规则（前次崩溃/强制退出残留）
    // 单用户场景下，启动新实例时旧规则即为无效规则
    let old_rules = crate::hdc::fport_list_for_device(hdc_path, sn).unwrap_or_default();
    for port in old_rules {
        let _ = crate::hdc::fport_rm(hdc_path, sn, port);
        if verbose { eprintln!("[ohscrcpy] cleaned up previous fport tcp:{}", port); }
    }

    // 尝试启动服务（忽略错误，服务可能已经在运行）
    let _ = hdc::shell(hdc_path, sn, "aa start -a ScrcpyService -b com.ohos.scrcpy.server");

    // 轮询端口 53535 是否在监听
    for i in 0..30 {
        std::thread::sleep(std::time::Duration::from_millis(500));
        let out = hdc::shell(hdc_path, sn, "netstat -an 2>/dev/null | grep 53535").unwrap_or_default();
        if out.contains("53535") && out.contains("LISTEN") {
            if verbose { eprintln!("[ohscrcpy] service port 53535 is ready"); }
            return Ok(());
        }
        if verbose && i % 4 == 0 {
            eprintln!("[ohscrcpy] waiting for service... ({}/30)", i + 1);
        }
    }
    Err(anyhow::anyhow!("service port 53535 not ready after 15s"))
}
