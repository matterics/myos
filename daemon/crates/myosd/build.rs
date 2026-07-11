fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut includes = vec!["../../../proto".to_string()];
    for candidate in ["/usr/include", "/usr/local/include"] {
        if std::path::Path::new(candidate)
            .join("google/protobuf/empty.proto")
            .exists()
        {
            includes.push(candidate.to_string());
        }
    }
    tonic_build::configure()
        .build_client(false)
        .compile_protos(&["../../../proto/agent.proto"], &includes)?;
    println!("cargo:rerun-if-changed=../../../proto/agent.proto");
    Ok(())
}
