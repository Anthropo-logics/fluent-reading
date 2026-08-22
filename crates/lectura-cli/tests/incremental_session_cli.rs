use std::process::Command;

#[test]
fn session_plan_prioritizes_the_visible_page() {
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args([
            "session",
            "plan",
            "--pages",
            "5",
            "--visible",
            "3",
            "--json",
        ])
        .output()
        .expect("CLI should start");
    assert!(output.status.success());
    let event: serde_json::Value = serde_json::from_slice(&output.stdout).expect("valid JSON");
    assert_eq!(event["result"]["pages"][3]["state"], "processing");
    assert_eq!(event["result"]["visible_page_index"], 3);
}

#[test]
fn session_plan_rejects_an_out_of_range_page() {
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args([
            "session",
            "plan",
            "--pages",
            "2",
            "--visible",
            "2",
            "--json",
        ])
        .output()
        .expect("CLI should start");
    assert!(!output.status.success());
}
