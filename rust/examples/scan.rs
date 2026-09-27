//! Diagnostic entry point using the same C ABI as the Swift app.
use diskscope_scanner::*;
use std::ffi::{CStr, CString};
use std::time::{Duration, Instant};

fn main() {
    let path = CString::new(std::env::args().nth(1).expect("Usage: scan <directory>")).unwrap();
    let id = unsafe { ds_scan_start(path.as_ptr()) };
    assert_ne!(id, 0);
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        let pointer = ds_scan_poll(id);
        assert!(!pointer.is_null());
        let state = unsafe { CStr::from_ptr(pointer).to_string_lossy().into_owned() };
        unsafe { ds_string_free(pointer) };
        if state.contains("\"status\":\"complete\"") {
            let pointer = ds_scan_take_result(id);
            assert!(!pointer.is_null());
            println!("{}", unsafe { CStr::from_ptr(pointer).to_string_lossy() });
            unsafe { ds_string_free(pointer) };
            ds_scan_destroy(id);
            break;
        }
        if state.contains("\"status\":\"failed\"") || Instant::now() > deadline {
            ds_scan_destroy(id);
            panic!("Scan failed: {state}");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
