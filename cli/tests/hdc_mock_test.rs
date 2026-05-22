/// hdc 输出解析的 mock 测试（不需要真实设备）

/// 模拟 `hdc list targets` 输出，验证设备列表解析
#[test]
fn test_parse_device_list_single() {
    let mock_output = "SN_ABC123\n";
    let devices = parse_hdc_list_targets(mock_output);
    assert_eq!(devices, vec!["SN_ABC123"]);
}

#[test]
fn test_parse_device_list_multiple() {
    let mock_output = "SN_ABC123\nSN_DEF456\n";
    let devices = parse_hdc_list_targets(mock_output);
    assert_eq!(devices.len(), 2);
    assert!(devices.contains(&"SN_ABC123".to_string()));
    assert!(devices.contains(&"SN_DEF456".to_string()));
}

#[test]
fn test_parse_device_list_empty() {
    let devices = parse_hdc_list_targets("Empty\n");
    assert!(devices.is_empty());
}

#[test]
fn test_parse_device_list_ignores_brackets() {
    // hdc 有时会输出 "[Empty]" 或状态行
    let mock_output = "[HDC Server] ... connecting\nSN_XYZ789\n";
    let devices = parse_hdc_list_targets(mock_output);
    assert_eq!(devices, vec!["SN_XYZ789"]);
}

/// 模拟 `hdc fport ls` 输出，验证冲突检测逻辑
#[test]
fn test_fport_conflict_detection_same_device() {
    // 同设备 SN_ABC123 已有 fport 规则
    let mock_fport_ls = "[Forward]:  SN_ABC123   tcp:5001   tcp:53535\n";
    let rules = parse_fport_ls(mock_fport_ls);
    let conflict = rules.iter().any(|r| r.serial == "SN_ABC123" && r.pc_port != 53535);
    assert!(conflict, "same device conflict should be detected");
}

#[test]
fn test_fport_no_conflict_different_device() {
    let mock_fport_ls = "[Forward]:  SN_DEF456   tcp:5001   tcp:53535\n";
    let rules = parse_fport_ls(mock_fport_ls);
    let conflict = rules.iter().any(|r| r.serial == "SN_ABC123");
    assert!(!conflict, "different device should not be a conflict");
}

#[test]
fn test_fport_empty() {
    let rules = parse_fport_ls("");
    assert!(rules.is_empty());
}

#[test]
fn test_free_port_selection() {
    // 5000 已被占用，应选 5001
    let used: std::collections::HashSet<u16> = [5000].into_iter().collect();
    let port = find_free_port_from_set(&used);
    assert_eq!(port, Some(5001));
}

#[test]
fn test_free_port_all_taken() {
    let used: std::collections::HashSet<u16> = (5000..5100).collect();
    let port = find_free_port_from_set(&used);
    assert!(port.is_none());
}

// ──────────────────────── 测试辅助函数 ────────────────────────

fn parse_hdc_list_targets(output: &str) -> Vec<String> {
    output
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty() && !l.starts_with('[') && l != "Empty")
        .collect()
}

#[derive(Debug)]
struct MockFportRule { serial: String, pc_port: u16 }

fn parse_fport_ls(output: &str) -> Vec<MockFportRule> {
    let mut rules = Vec::new();
    for line in output.lines() {
        if !line.contains("tcp:53535") { continue; }
        // 提取 serial（[Forward]: 后第一个 token）
        let serial = line.splitn(2, ':').nth(1)
            .and_then(|r| r.split_whitespace().next())
            .unwrap_or("").to_string();
        // 提取 pc_port（tcp:xxxx 非 53535）
        for part in line.split_whitespace() {
            if let Some(rest) = part.strip_prefix("tcp:") {
                if let Ok(port) = rest.trim_end_matches(|c: char| !c.is_ascii_digit()).parse::<u16>() {
                    if port != 53535 {
                        rules.push(MockFportRule { serial: serial.clone(), pc_port: port });
                        break;
                    }
                }
            }
        }
    }
    rules
}

fn find_free_port_from_set(used: &std::collections::HashSet<u16>) -> Option<u16> {
    (5000u16..5100).find(|p| !used.contains(p))
}
