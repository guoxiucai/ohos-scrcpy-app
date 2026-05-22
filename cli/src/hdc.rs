use anyhow::{anyhow, Context, Result};
use std::path::PathBuf;
use std::process::Command;

// ──────────────────────── hdc 查找 ────────────────────────

/// 查找系统中的 hdc 可执行文件
pub fn find_hdc() -> Result<PathBuf> {
    // 先尝试 PATH 中的 hdc
    if let Ok(output) = Command::new("which").arg("hdc").output() {
        if output.status.success() {
            let path_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path_str.is_empty() {
                return Ok(PathBuf::from(path_str));
            }
        }
    }

    // DevEco Studio 默认安装路径（macOS）
    let defaults = [
        "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
        "/Applications/DevEco-Studio.app/Contents/tools/hdc/bin/hdc",
        "/Users/robinyeung/Library/Huawei/Sdk/HarmonyOS-NEXT-DP2/base/toolchains/hdc",
        "/usr/local/bin/hdc",
        "/opt/homebrew/bin/hdc",
    ];
    for p in &defaults {
        let path = PathBuf::from(p);
        if path.exists() {
            return Ok(path);
        }
    }

    Err(anyhow!(
        "hdc not found. Install DevEco Studio or add hdc to your PATH.\n  \
         Download: https://developer.huawei.com/consumer/cn/deveco-studio/"
    ))
}

// ──────────────────────── 设备列表 ────────────────────────

/// 列出所有已连接设备的序列号
pub fn list_devices(hdc: &PathBuf) -> Result<Vec<String>> {
    let output = Command::new(hdc)
        .arg("list")
        .arg("targets")
        .output()
        .context("running 'hdc list targets'")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let serials: Vec<String> = stdout
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty() && !l.starts_with('[') && l != "Empty")
        .collect();

    Ok(serials)
}

// ──────────────────────── 端口转发 ────────────────────────

#[derive(Debug, Clone)]
pub struct FportRule {
    pub serial: String,
    pub pc_port: u16,
}

/// 列出当前所有 fport 规则
pub fn fport_list(hdc: &PathBuf) -> Result<Vec<FportRule>> {
    let output = Command::new(hdc)
        .arg("fport")
        .arg("ls")
        .output()
        .context("running 'hdc fport ls'")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut rules = Vec::new();

    for line in stdout.lines() {
        // 格式示例：[Forward]:  <serial>   tcp:<pc_port>  tcp:53535
        if !line.contains("tcp:53535") {
            continue;
        }
        // 提取 tcp:<pc_port>
        if let Some(pc_port) = extract_pc_port(line) {
            let serial = extract_serial(line).unwrap_or_default();
            rules.push(FportRule { serial, pc_port });
        }
    }
    Ok(rules)
}

fn extract_pc_port(line: &str) -> Option<u16> {
    // 找 "tcp:<digits>" 不是 53535 的部分
    for part in line.split_whitespace() {
        if let Some(rest) = part.strip_prefix("tcp:") {
            if let Ok(port) = rest.trim_end_matches(|c: char| !c.is_ascii_digit()).parse::<u16>() {
                if port != 53535 {
                    return Some(port);
                }
            }
        }
    }
    None
}

fn extract_serial(line: &str) -> Option<String> {
    // 序列号通常在 "[Forward]:" 之后第一个空白分隔的 token
    let rest = line.splitn(2, ':').nth(1)?;
    let token = rest.split_whitespace().next()?;
    if !token.is_empty() {
        Some(token.to_string())
    } else {
        None
    }
}

/// 列出指定设备的所有 fport 规则
pub fn fport_list_for_device(hdc: &PathBuf, sn: &str) -> Result<Vec<u16>> {
    let output = Command::new(hdc)
        .args(["-t", sn, "fport", "ls"])
        .output()
        .context("running 'hdc -t <sn> fport ls'")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut ports = Vec::new();

    for line in stdout.lines() {
        if !line.contains("tcp:53535") { continue; }
        if let Some(pc_port) = extract_pc_port(line) {
            ports.push(pc_port);
        }
    }
    Ok(ports)
}

/// 在 5000–5099 范围内找一个未被占用的端口；若目标设备已有规则则报错
pub fn find_free_port(hdc: &PathBuf, sn: &str) -> Result<u16> {
    let device_ports = fport_list_for_device(hdc, sn)?;

    // 检查同设备是否已有实例
    if let Some(&existing_port) = device_ports.first() {
        return Err(anyhow!(
            "another ohscrcpy instance is already running for device {} (port {} in use).",
            sn, existing_port
        ));
    }

    // 查找全局未使用端口（避免与其他设备冲突；失败时忽略）
    let all_rules = fport_list(hdc).unwrap_or_default();
    let used: std::collections::HashSet<u16> = all_rules.iter().map(|r| r.pc_port).collect();
    for port in 5000u16..5100 {
        if !used.contains(&port) {
            return Ok(port);
        }
    }
    Err(anyhow!("no free ports available in range 5000-5099"))
}

/// 添加端口转发规则
pub fn fport_add(hdc: &PathBuf, sn: &str, pc_port: u16) -> Result<()> {
    let output = Command::new(hdc)
        .args(["-t", sn, "fport", &format!("tcp:{}", pc_port), "tcp:53535"])
        .output()
        .context("running 'hdc fport'")?;

    if !output.status.success() {
        let err = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!("fport failed: {}", err));
    }
    Ok(())
}

/// 删除端口转发规则（退出时清理）
pub fn fport_rm(hdc: &PathBuf, sn: &str, pc_port: u16) -> Result<()> {
    Command::new(hdc)
        .args(["-t", sn, "fport", "rm", &format!("tcp:{}", pc_port), "tcp:53535"])
        .output()
        .ok(); // 尽力清理，忽略错误
    Ok(())
}

// ──────────────────────── shell 命令 ────────────────────────

/// 在设备上执行 shell 命令，返回 stdout
pub fn shell(hdc: &PathBuf, sn: &str, cmd: &str) -> Result<String> {
    let output = Command::new(hdc)
        .args(["-t", sn, "shell", cmd])
        .output()
        .with_context(|| format!("hdc shell: {}", cmd))?;
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}
