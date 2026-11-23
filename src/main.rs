use std::{env,fs,io::{self,Write},path::Path,process::{Command,exit}};

const WG_CONFIG: &str = "/etc/wireguard/wg-vk.conf";
const SRTP_SERVICE: &str = "/etc/systemd/system/vk-srtp.service";
const WG_SERVICE: &str = "wg-quick@wg-vk";
const SRTP_UNIT: &str = "vk-srtp";

fn run(program: &str, args: &[&str]) -> Result<(),String> {
    let status = Command::new(program).args(args).status()
        .map_err(|e| format!("{program}: {e}"))?;
    if status.success() { Ok(()) } else { Err(format!("{program} {:?}: exited {status}",args)) }
}
fn root() -> Result<(),String> {
    let output=Command::new("id").arg("-u").output().map_err(|e|e.to_string())?;
    if output.stdout != b"0\n" {return Err("Run as root: sudo vk-turn-manager ...".into())}
    Ok(())
}
fn install(wg_source: &str,srtp_binary: &str,srtp_args: &[String]) -> Result<(),String> {
    root()?;
    let source=Path::new(wg_source);
    if !source.is_file() {return Err(format!("WireGuard configuration missing: {wg_source}"))}
    let binary=fs::canonicalize(srtp_binary).map_err(|e|format!("SRTP executable: {e}"))?;
    if !binary.is_file() {return Err("SRTP executable is not a file".into())}
    if srtp_args.iter().any(|s|s.contains('\n') || s.contains('\r')) {
        return Err("Newlines are not allowed in SRTP arguments".into())
    }
    // Refuse to replace pre-existing configuration: never destroy a working VPN.
    if Path::new(WG_CONFIG).exists() || Path::new(SRTP_SERVICE).exists() {
        return Err("Existing configuration detected. Refusing to overwrite it.".into())
    }
    run("apt-get",&["update"])?;
    run("apt-get",&["install","-y","wireguard","wireguard-tools"])?;
    fs::create_dir_all("/etc/wireguard").map_err(|e|e.to_string())?;
    let conf=fs::read(wg_source).map_err(|e|e.to_string())?;
    if conf.is_empty() {return Err("WireGuard config is empty".into())}
    let mut f=fs::OpenOptions::new().write(true).create_new(true).open(WG_CONFIG).map_err(|e|e.to_string())?;
    f.write_all(&conf).map_err(|e|e.to_string())?;
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(WG_CONFIG,fs::Permissions::from_mode(0o600)).map_err(|e|e.to_string())?;
    }
    // systemd's ExecStart quoting: encode every argument as a quoted token.
    fn quote(s:&str)->String {
        format!("\"{}\"",s.replace('\\',"\\\\").replace('"',"\\\"").replace('%',"%%"))
    }
    let mut cmd=quote(&binary.to_string_lossy());
    for arg in srtp_args {cmd.push(' ');cmd.push_str(&quote(arg));}
    let unit=format!("[Unit]\nDescription=VK SRTP relay\nAfter=network-online.target {}.service\nWants=network-online.target\n\n[Service]\nType=simple\nExecStart={}\nRestart=on-failure\nRestartSec=3\nNoNewPrivileges=true\n\n[Install]\nWantedBy=multi-user.target\n",WG_SERVICE,cmd);
    fs::write(SRTP_SERVICE,unit).map_err(|e|e.to_string())?;
    run("systemctl",&["daemon-reload"])?;
    run("systemctl",&["enable","--now",WG_SERVICE])?;
    run("systemctl",&["enable","--now",SRTP_UNIT])?;
    println!("Installed. Verify with: vk-turn-manager status");
    Ok(())
}
fn status()->Result<(),String> {
    run("systemctl",&["--no-pager","--full","status",WG_SERVICE])?;
    run("systemctl",&["--no-pager","--full","status",SRTP_UNIT])
}
fn uninstall()->Result<(),String> {
    root()?;
    for unit in [SRTP_UNIT,WG_SERVICE] {
        let _=run("systemctl",&["disable","--now",unit]);
    }
    if Path::new(SRTP_SERVICE).exists() {fs::remove_file(SRTP_SERVICE).map_err(|e|e.to_string())?;}
    // Deliberately retain /etc/wireguard/wg-vk.conf and any SRTP executable.
    run("systemctl",&["daemon-reload"])?;
    println!("Services removed. WireGuard config and SRTP executable were retained.");
    Ok(())
}
fn usage() {
    eprintln!("Usage:\n  vk-turn-manager install <wg-config-file> <srtp-executable> [srtp-args...]\n  vk-turn-manager status\n  vk-turn-manager uninstall");
}
fn main(){
    let args:Vec<String>=env::args().collect();
    let result=match args.get(1).map(String::as_str) {
        Some("install") if args.len()>=4 => install(&args[2],&args[3],&args[4..]),
        Some("status") if args.len()==2 => status(),
        Some("uninstall") if args.len()==2 => uninstall(),
        _=>{usage();exit(2)}
    };
    if let Err(e)=result {eprintln!("Error: {e}");exit(1)}
}
