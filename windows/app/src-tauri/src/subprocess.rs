/// Native AI/MCP/decoder process trees end with their request or the application.
#[cfg(windows)]
pub struct Job(std::os::windows::io::OwnedHandle);
#[cfg(not(windows))]
pub struct Job;
pub fn attach(child: &mut std::process::Child) -> Result<Job, String> {
    #[cfg(windows)]
    {
        use std::os::windows::io::{AsRawHandle, FromRawHandle};
        use windows::Win32::{Foundation::HANDLE, System::JobObjects::*};
        let result = (|| unsafe {
            let handle = CreateJobObjectW(None, None).map_err(|e| e.to_string())?;
            let owned = std::os::windows::io::OwnedHandle::from_raw_handle(handle.0);
            let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const std::ffi::c_void,
                std::mem::size_of_val(&info) as u32,
            )
            .map_err(|e| e.to_string())?;
            AssignProcessToJobObject(handle, HANDLE(child.as_raw_handle()))
                .map_err(|e| e.to_string())?;
            Ok(Job(owned))
        })();
        if result.is_err() {
            let _ = child.kill();
            let _ = child.wait();
        }
        result
    }
    #[cfg(not(windows))]
    {
        let _ = child;
        Ok(Job)
    }
}
#[cfg(windows)]
impl Drop for Job {
    fn drop(&mut self) {
        use std::os::windows::io::AsRawHandle;
        let _ = self.0.as_raw_handle();
    }
}
