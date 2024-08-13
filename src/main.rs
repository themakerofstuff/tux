use std::env;
use package_manager::*;

fn main(){
    sudo::escalate_if_needed().expect("nope");
    let args: Vec<String> = env::args().collect();
    let option = if args.get(1) != None { &args[1] } else { "" };
    let package = if args.get(2) != None { &args[2] } else { "" };

    match option {
        "install" => tux_install(package),
        _ => tux_help(),
    };
}
