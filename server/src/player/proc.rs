//! The mpv behind a session, as far as the loop needs it: is it alive, wait
//! for it to end, kill it: a child process on Windows and macOS.

pub use desktop::MpvProc;

mod desktop {
    use std::process::Stdio;

    use tokio::process::Command;

    use super::super::mpv;

    pub struct MpvProc {
        child: tokio::process::Child,
    }

    impl MpvProc {
        pub fn spawn(args: &[String]) -> Result<Self, String> {
            let binary = mpv::locate().ok_or_else(|| mpv::NOT_FOUND.to_string())?;
            log::info!("[player] spawning {} {:?}", binary.display(), args);
            let child = Command::new(&binary)
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                // The server exiting any way but through `stop` must not leave a
                // player behind reading from a range server that is gone.
                .kill_on_drop(true)
                .spawn()
                .map_err(|e| format!("could not start mpv at {}: {e}", binary.display()))?;
            #[cfg(windows)]
            bind_to_server_lifetime(&child);
            Ok(Self { child })
        }

        pub fn alive(&mut self) -> bool {
            matches!(self.child.try_wait(), Ok(None))
        }

        /// How it ended, for the log.
        pub async fn wait(&mut self) -> String {
            format!("{:?}", self.child.wait().await)
        }

        pub async fn kill(&mut self) {
            let _ = self.child.kill().await;
        }
    }

    /// Puts mpv in a job object that dies with this process. `kill_on_drop` only
    /// runs when the server unwinds normally; Task Manager, a crash, or the
    /// installer's `Stop-Process` end the server without dropping anything, and
    /// mpv would stay open on a stream whose server is gone. The job handle is
    /// deliberately leaked: closing it is what kills the children, and the OS
    /// closes it when this process exits, however it exits.
    #[cfg(windows)]
    fn bind_to_server_lifetime(child: &tokio::process::Child) {
        use windows_sys::Win32::System::JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        };
        let Some(process) = child.raw_handle() else { return };
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
                log::warn!("[player] could not create a job object; mpv may outlive a crashed server");
                return;
            }
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let ok = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const core::ffi::c_void,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
            if ok == 0 || AssignProcessToJobObject(job, process as _) == 0 {
                log::warn!("[player] could not bind mpv to the server's lifetime; mpv may outlive a crashed server");
            }
        }
    }
}
