use std::collections::BTreeSet;

use harmonia_store_derivation::derivation::Derivation;
use harmonia_store_derivation::derived_path::{OutputName, SingleDerivedPath};
use harmonia_store_path::StorePath;

/// Output names of intermediate derivations for a dynamic derivation
/// dependency, stored in reverse order so that the next level to resolve
/// can be cheaply `pop()`-ed.
///
/// e.g. for a derivation input that is `aaaa-dyn.drv^foo^bar^out`, the final
/// derivation would be `aaaa-dyn.drv^foo^bar` (no final `^out`). The output
/// names are stored as `["bar", "foo"]` (reversed).
///
/// In the common case of depending on a static derivation, this is empty.
#[derive(Debug, Clone, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct OutputNameChain(pub Vec<OutputName>);

impl OutputNameChain {
    pub fn pop(&mut self) -> Option<OutputName> {
        self.0.pop()
    }
}

/// Flatten a [`SingleDerivedPath`] into `(root_drv_path, chain)`.
///
/// The output chain is in stack order (outermost first) matching
/// [`OutputNameChain`]'s convention. For `Built { Opaque(A), "foo" }`,
/// returns `(A, ["foo"])`. For `Opaque(A)`, returns `(A, [])`.
#[must_use]
pub fn flatten_path(sdp: &SingleDerivedPath) -> (StorePath, OutputNameChain) {
    let mut current = sdp;
    let mut outputs = Vec::new();
    loop {
        match current {
            SingleDerivedPath::Opaque(p) => return (p.clone(), OutputNameChain(outputs)),
            SingleDerivedPath::Built { drv_path, output } => {
                outputs.push(output.clone());
                current = drv_path;
            }
        }
    }
}

/// Like [`flatten_path`] but prepends the additional, outermost output name.
///
/// For `Built { Opaque(A), "foo" }` with output `"bar"`,
/// returns `(A, ["bar", "foo"])`.
#[must_use]
pub fn flatten_chain(
    drv_path: &SingleDerivedPath,
    output_name: &OutputName,
) -> (StorePath, OutputNameChain) {
    let (root, mut chain) = flatten_path(drv_path);
    chain.0.insert(0, output_name.clone());
    (root, chain)
}

/// Extract `Built` input dependencies from a derivation.
///
/// Returns `(root_drv_path, relation)` pairs. `Opaque` (source) inputs are
/// skipped — only derivation build dependencies are returned. For each
/// `Built` input, the outermost output name (what we consume) is discarded;
/// intermediate output names form the [`OutputNameChain`].
pub fn input_drvs(drv: &Derivation) -> BTreeSet<(StorePath, OutputNameChain)> {
    drv.inputs
        .iter()
        .filter_map(|sdp| match sdp {
            SingleDerivedPath::Opaque(_) => None,
            SingleDerivedPath::Built { drv_path, .. } => Some(flatten_path(drv_path)),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn path(suffix: &str) -> SingleDerivedPath {
        format!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-root.drv{suffix}")
            .parse()
            .unwrap()
    }

    fn names(names: &[&str]) -> Vec<OutputName> {
        names.iter().map(|name| name.parse().unwrap()).collect()
    }

    #[test]
    fn flatten_opaque_and_static_output() {
        let (root, chain) = flatten_path(&path(""));
        assert_eq!(
            root.to_string(),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-root.drv"
        );
        assert!(chain.0.is_empty());
        assert_eq!(flatten_path(&path("^foo")).1.0, names(&["foo"]));
    }

    #[test]
    fn distinct_dynamic_outputs_are_in_stack_order() {
        let (_, mut chain) = flatten_path(&path("^foo^bar^bin"));
        assert_eq!(chain.0, names(&["bin", "bar", "foo"]));
        for name in names(&["foo", "bar", "bin"]) {
            assert_eq!(chain.pop(), Some(name));
        }
        assert_eq!(chain.pop(), None);
    }

    #[test]
    fn flatten_chain_adds_outermost_output() {
        let (_, chain) = flatten_chain(&path("^foo^bar"), &"bin".parse().unwrap());
        assert_eq!(chain.0, names(&["bin", "bar", "foo"]));
    }

    #[test]
    fn dependency_relation_excludes_consumed_output() {
        let drv = Derivation {
            name: "consumer".parse().unwrap(),
            outputs: Default::default(),
            inputs: [path("^foo^bar^out"), path("")].into_iter().collect(),
            platform: "x86_64-linux".into(),
            builder: "/bin/sh".into(),
            args: Vec::new(),
            env: Default::default(),
            structured_attrs: None,
        };
        let (root, _) = flatten_path(&path(""));
        assert_eq!(
            input_drvs(&drv),
            [(root, OutputNameChain(names(&["bar", "foo"])))]
                .into_iter()
                .collect()
        );
    }
}
