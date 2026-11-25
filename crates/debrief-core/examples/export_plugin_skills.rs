//! Regenerate checked-in plugin skills from the installer's source of truth.
use debrief_core::EmbeddedTemplates;
use std::{fs, path::Path};

fn main() -> std::io::Result<()> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../plugins/debrief/skills");
    for (name, content) in EmbeddedTemplates::skills(Path::new("debrief")) {
        let folder = root.join(name);
        fs::create_dir_all(&folder)?;
        fs::write(folder.join("SKILL.md"), content)?;
    }
    Ok(())
}
