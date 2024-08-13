use serde_json;
use serde::{Serialize,Deserialize};
use std::{io::{self, Read, BufReader, BufRead, stdin}, fs, process, path::Path};
use colored::Colorize;
use git2::Repository;

const REPO_FILE: &str = "/etc/tux/repository";
const REPO_DIR: &str = "/var/lib/tux/repository";

#[derive(Serialize,Deserialize)]
pub struct JSONPackage {
    pub name: String,
    pub version: String,
    pub patches: bool,
    pub filename: String,
    pub url: String,
    pub depends: Vec<String>,
}

pub fn tux_read_package_json(json_file: &str) -> Result<JSONPackage, io::Error> {
    let file_open = fs::File::open(json_file);
    let mut file = if let Ok(open_file) = file_open {
        open_file
    } else {
        tux_error("Failed to open package JSON file");
        process::exit(1);
    };
    let mut data = String::from(r#""#);
    file.read_to_string(&mut data)?;
    let package_keys: JSONPackage = serde_json::from_str(&data)?;

    Ok(package_keys)
}

pub fn tux_help() {
    println!("");
    println!("{}", "Tux: a package manager written in Rust".white());
    println!("");
    println!("{}", "Usage:".white());
    println!("{}", "tux [COMMAND] (PACKAGE)".blue());
    println!("");
    println!("{}", "Commands:".white());
    println!("{} {}", "install:".blue(), "Installs [PACKAGE] to your system".white());
    println!("{} {}", "remove:".blue(), "Removes [PACKAGE] from your system".white());
    println!("{} {}", "update:".blue(), "Updates package repository".white());
    println!("{} {}", "build:".blue(), "Builds [PACKAGE] without installing it, useful for building packages for other systems".white());
    println!("{} {}", "install-from-archive:".blue(), "Installs [PACKAGE] archive from your system".white());
    println!("");
    process::exit(0);
}

pub fn tux_error(error: &str) {
    println!("{} {}", ">>>".red(), error.white());
}

pub fn tux_info(info: &str) {
    println!("{} {}", ">>>".blue(), info.white());
}

pub fn tux_success(success: &str) {
    println!("{} {}", ">>>".green(), success.white());
}

pub fn tux_find_package(package: &str) -> bool {
    let index_file = REPO_DIR.to_owned() + "/index";
    let mut url = if let Ok(file) = fs::read_to_string(REPO_FILE) { file } else { tux_error("Unable to read package index file"); process::exit(1); };
    url.pop();
    if ! Path::new(REPO_DIR).exists() {
        tux_info("Package repository not found, cloning it...");
        if let Err(_) = Repository::clone(&url, REPO_DIR) { tux_error("Unable to clone package repository"); process::exit(1); };
    };
    let index = if let Ok(file) = fs::File::open(index_file) { file } else { tux_error("Failed to open package index file"); process::exit(1); };
    let reader = BufReader::new(index);
    for line in reader.lines() {
        if let Ok(lines) = line {
            if lines == package {
                return true;
            };
        } else {
            return false;
        }
    };
    false
}

pub fn tux_resolve_dependencies(package_name: &str) -> Vec<String> {
    if tux_find_package(package_name) == false {
        tux_error(&("Unable to find package ".to_owned() + package_name));
        process::exit(1);
    };
    let mut dependencies: Vec<String> = vec![];
    let package_repo_dir = REPO_DIR.to_owned() + "/" + package_name;
    let package_json = package_repo_dir + "/package.json";
    if ! Path::new(&package_json).exists() {
        tux_error("package.json file not found, you might need to update the repository");
        process::exit(1);
    };
    let package = if let Ok(json) = tux_read_package_json(&package_json) { json } else {
        tux_error("Failed to read package.json file");
        process::exit(1);
    };
    for i in package.depends.iter() {
        dependencies.push(i.to_string());
        dependencies.extend(tux_resolve_dependencies(i));
    };

    dependencies
}

pub fn tux_install(package_name: &str) {
    let mut dependencies = tux_resolve_dependencies(package_name);
    dependencies.push(package_name.to_string());
    tux_info("The following packages will be installed:");
    for i in dependencies.iter() {
        print!("{} ", i);
    };
    print!("\n");
    print!("{} {}", ">>>".blue(), "Do you want to continue? [Y/N]".white());
    let mut option: String = String::new();
    io::stdin().read_line(&mut option).expect("Failed to read from stdin");
    if option == "n" || option == "N" {
        process::exit(1);
    };
    print!("\n");
    for depend in dependencies.iter() {
        let build_dir = "/var/lib/tux/".to_owned() + depend;
        let package_json = REPO_DIR.to_owned() + "/" + depend + "/package.json";
        if ! Path::new(&build_dir).exists() {
            if let Err(_) = fs::create_dir(&build_dir) { tux_error("Failed to create build directory"); process::exit(1); };
        }
        let package = if let Ok(json) = tux_read_package_json(&package_json) { json } else {
            tux_error("Failed to read package.json file");
            fs::remove_dir_all(&build_dir).expect("failed to remove build directory");
            process::exit(1);
        };
        tux_info(&("Downloading package ".to_owned() + depend + "-" + &package.version));
        let resp = if let Ok(resp) = reqwest::blocking::get(package.url) { resp } else { tux_error("Failed to download file, check your internet connection"); fs::remove_dir_all(&build_dir).expect("failed to remove dir"); process::exit(1); };
        let body = resp.text().expect("invalid url");
        let mut out = fs::File::create(build_dir.clone() + "/" + &package.filename).expect("failed to create file");
        if let Err(_) = io::copy(&mut body.as_bytes(), &mut out) {
            tux_error("Failed to download file, check your internet connection");
            fs::remove_dir_all(&build_dir).expect("failed to remove dir");
            process::exit(1);
        };
    }
}