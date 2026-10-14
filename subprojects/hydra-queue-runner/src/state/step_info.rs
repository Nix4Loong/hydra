use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use db::models::BuildID;
use harmonia_store_derivation::derivation::{BasicDerivation, Derivation};
use harmonia_store_derivation::derived_path::{OutputName, SingleDerivedPath};
use harmonia_store_path::{StoreDir, StorePath};

use super::Step;
use super::drv::{OutputNameChain, flatten_chain};
use crate::config::StepSortFn;

/// Resolve an input-addressed derivation output from the `.drv` file on
/// disk. The build-history lookup in the database can miss outputs that
/// never got a successful build step row, e.g. paths that were already
/// valid when the step was created or whose step was aborted by a
/// restart after the build finished. For input-addressed derivations the
/// output path is fixed by the derivation itself, so the file is
/// authoritative.
fn resolve_from_drv_file(
    store_dir: &StoreDir,
    drv_path: &StorePath,
    output_name: &OutputName,
) -> Option<StorePath> {
    let path = std::path::PathBuf::from(store_dir.display(drv_path).to_string());
    let content = fs_err::read(path).ok()?;
    let name = drv_path.name().strip_suffix(".drv")?.parse().ok()?;
    let drv = harmonia_store_aterm::parse_derivation_aterm(store_dir, &content, name).ok()?;
    let output = drv.outputs.get(output_name)?;
    output
        .path(store_dir, &drv.name, output_name)
        .ok()
        .flatten()
}

/// Walk dynamic output chains one level at a time. Read authoritative .drv
/// outputs first, then query all remaining links at that level in one batch.
/// The memo includes misses and is shared across chains and levels.
fn resolve_input_chains(
    chains: &[(StorePath, OutputNameChain)],
    mut read_drv: impl FnMut(&StorePath, &OutputName) -> Option<StorePath>,
    mut query_batch: impl FnMut(&[(StorePath, OutputName)]) -> Vec<Option<StorePath>>,
) -> Vec<Option<StorePath>> {
    let mut states: Vec<_> = chains.iter().cloned().map(Some).collect();
    let mut memo = HashMap::<(StorePath, OutputName), Option<StorePath>>::new();
    loop {
        let mut active = false;
        let mut missing = Vec::new();
        let mut seen = HashSet::new();
        for (current, chain) in states.iter().flatten() {
            let Some(output) = chain.0.last() else {
                continue;
            };
            active = true;
            let key = (current.clone(), output.clone());
            if memo.contains_key(&key) || !seen.insert(key.clone()) {
                continue;
            }
            if let Some(path) = read_drv(current, output) {
                memo.insert(key, Some(path));
            } else {
                missing.push(key);
            }
        }
        if !active {
            break;
        }
        if !missing.is_empty() {
            let results = query_batch(&missing);
            assert_eq!(results.len(), missing.len());
            memo.extend(missing.into_iter().zip(results));
        }
        for state in &mut states {
            let Some((current, chain)) = state else {
                continue;
            };
            let Some(output) = chain.pop() else { continue };
            match memo.get(&(current.clone(), output)).cloned().flatten() {
                Some(path) => *current = path,
                None => *state = None,
            }
        }
    }
    states
        .into_iter()
        .map(|state| state.map(|(path, _)| path))
        .collect()
}

#[derive(Debug)]
pub struct StepInfo {
    pub step: Arc<Step>,
    already_scheduled: AtomicBool,
    cancelled: AtomicBool,
    pub runnable_since: jiff::Timestamp,
    lowest_share_used: atomic_float::AtomicF64,
}

impl StepInfo {
    pub fn new(step: Arc<Step>) -> Self {
        Self {
            already_scheduled: false.into(),
            cancelled: false.into(),
            runnable_since: step.get_runnable_since(),
            lowest_share_used: step.get_lowest_share_used().into(),
            step,
        }
    }

    /// Resolve a derivation's inputs into concrete store paths, returning a
    /// [`BasicDerivation`](BasicDerivation).
    ///
    /// Returns [`None`] if resolution fails because required outputs have not
    /// been built yet or cannot be looked up.
    ///
    /// If the derivation has no [`Built`](SingleDerivedPath::Built) inputs, it is
    /// already resolved; the inputs are simply flattened to a [`StorePathSet`].
    ///
    /// IA output paths come from local .drv files; CA output paths come from the
    /// Hydra database, including persisted resolved derivation mappings.
    pub(super) async fn try_resolve_force(
        store_dir: &StoreDir,
        db: &db::Database,
        drv: &Derivation,
    ) -> Option<BasicDerivation> {
        // If there are no Built inputs, the derivation is already resolved.
        let has_built_inputs = drv
            .inputs
            .iter()
            .any(|i| matches!(i, SingleDerivedPath::Built { .. }));
        if !has_built_inputs {
            return Some(drv.clone().map_inputs(|inputs| {
                inputs
                    .into_iter()
                    .map(|sdp| match sdp {
                        SingleDerivedPath::Opaque(p) => p,
                        SingleDerivedPath::Built { .. } => unreachable!(),
                    })
                    .collect()
            }));
        }

        let mut conn = db.get().await.ok()?;

        drv.try_resolve_force(store_dir, &mut |inputs| {
            tokio::task::block_in_place(|| {
                // Flatten each SingleDerivedPath chain into (root, [outputs...])
                // and resolve links with a shared memo for this batch.
                let chains: Vec<_> = inputs
                    .iter()
                    .map(|(drv_path, output_name)| flatten_chain(drv_path, output_name))
                    .collect();

                let rt = tokio::runtime::Handle::current();
                resolve_input_chains(
                    &chains,
                    |path, output| resolve_from_drv_file(store_dir, path, output),
                    |links| {
                        // This query follows persisted resolvedDrvPath mappings for CA
                        // outputs. Historical IA output-name mistakes are bypassed by
                        // the authoritative .drv lookup above.
                        let names: Vec<_> = links.iter().map(|(_, output)| [output]).collect();
                        let inputs: Vec<_> = links
                            .iter()
                            .zip(&names)
                            .map(|((path, _), names)| (path, names.as_slice()))
                            .collect();
                        rt.block_on(conn.resolve_drv_output_chains(store_dir, &inputs))
                            .unwrap_or_else(|e| {
                                tracing::warn!("resolve_drv_output_chains failed: {e}");
                                vec![None; links.len()]
                            })
                    },
                )
            })
        })
    }

    pub fn update_internal_stats(&self) {
        self.lowest_share_used
            .store(self.step.get_lowest_share_used(), Ordering::Relaxed);
    }

    pub fn get_lowest_share_used(&self) -> f64 {
        self.lowest_share_used.load(Ordering::Relaxed)
    }

    pub fn get_highest_global_priority(&self) -> i32 {
        self.step
            .atomic_state
            .highest_global_priority
            .load(Ordering::Relaxed)
    }

    pub fn get_highest_local_priority(&self) -> i32 {
        self.step
            .atomic_state
            .highest_local_priority
            .load(Ordering::Relaxed)
    }

    pub fn get_lowest_build_id(&self) -> BuildID {
        self.step
            .atomic_state
            .lowest_build_id
            .load(Ordering::Relaxed)
    }

    pub fn get_already_scheduled(&self) -> bool {
        self.already_scheduled.load(Ordering::SeqCst)
    }

    pub fn set_already_scheduled(&self, v: bool) {
        self.already_scheduled.store(v, Ordering::SeqCst);
    }

    pub fn set_cancelled(&self, v: bool) {
        self.cancelled.store(v, Ordering::SeqCst);
    }

    pub fn get_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// Snapshot the fields that `sort_fn` orders the queue by.
    pub(super) fn sort_key(&self, sort_fn: StepSortFn) -> SortKey {
        SortKey {
            global_priority: self.get_highest_global_priority(),
            share_used: self.get_lowest_share_used(),
            sort_fn_weight: match sort_fn {
                StepSortFn::Legacy => 0,
                StepSortFn::WithRdeps => self.step.get_rdeps_size(),
                StepSortFn::WithCriticalPath => self.step.get_cp_length(),
            },
            local_priority: self.get_highest_local_priority(),
            build_id: self.get_lowest_build_id(),
        }
    }
}

/// A step's position in the queue, read once per sort. The fields come from
/// live atomics. If the sort compared the atomics directly, they could change
/// mid-sort and break the total order that `sort_by` requires.
#[derive(Debug)]
pub(super) struct SortKey {
    global_priority: i32,
    share_used: f64,
    /// rdeps count or critical path length, depending on the sort function.
    /// Always 0 for Legacy.
    sort_fn_weight: u64,
    local_priority: i32,
    build_id: BuildID,
}

impl Ord for SortKey {
    /// Smaller keys sort first. Fields in order of precedence: higher global
    /// priority, lower share used, bigger `sort_fn_weight`, higher local priority,
    /// older build.
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        other
            .global_priority
            .cmp(&self.global_priority)
            .then(self.share_used.total_cmp(&other.share_used))
            .then(other.sort_fn_weight.cmp(&self.sort_fn_weight))
            .then(other.local_priority.cmp(&self.local_priority))
            .then(self.build_id.cmp(&other.build_id))
    }
}

impl PartialOrd for SortKey {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl PartialEq for SortKey {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == std::cmp::Ordering::Equal
    }
}

impl Eq for SortKey {}

#[cfg(test)]
mod tests {
    use super::*;
    use db::models::BuildID;
    use std::cmp::Ordering::{Equal, Greater, Less};

    fn sp(name: &str) -> StorePath {
        format!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-{name}")
            .parse()
            .unwrap()
    }

    fn on(name: &str) -> OutputName {
        name.parse().unwrap()
    }

    fn chain(root: &str, outputs: &[&str]) -> (StorePath, OutputNameChain) {
        // Start from the public SingleDerivedPath representation so these tests
        // also catch reversed flattening rather than hand-writing chain vectors.
        let path: SingleDerivedPath = format!("{}^{}", sp(root), outputs.join("^"))
            .parse()
            .unwrap();
        super::super::drv::flatten_path(&path)
    }

    fn write_ia_drv(store_dir: &StoreDir, name: &str, output: &str, path: &StorePath) {
        let text = format!(
            r#"Derive([("{output}","{}","","")],[],[],"x86_64-linux","/bin/sh",[],[])"#,
            store_dir.display(path),
        );
        fs_err::write(store_dir.display(&sp(name)).to_string(), text).unwrap();
    }

    #[test]
    fn ia_drv_overrides_wrong_historical_output() {
        let temp = tempfile::tempdir().unwrap();
        let store_dir = StoreDir::new(temp.path().to_str().unwrap()).unwrap();
        let expected = sp("authoritative-output");
        write_ia_drv(&store_dir, "producer.drv", "lib", &expected);
        let result = resolve_input_chains(
            &[chain("producer.drv", &["lib"])],
            |drv, output| resolve_from_drv_file(&store_dir, drv, output),
            |_| panic!("must not use the historical output recorded under the wrong name"),
        );
        assert_eq!(result, vec![Some(expected)]);
    }

    #[test]
    fn mixed_ia_ca_dynamic_chain_uses_distinct_outputs() {
        let temp = tempfile::tempdir().unwrap();
        let store_dir = StoreDir::new(temp.path().to_str().unwrap()).unwrap();
        write_ia_drv(&store_dir, "producer.drv", "foo", &sp("ca-link.drv"));
        let ca_drv = br#"Derive([("bar","","sha256","")],[],[],"x86_64-linux","/bin/sh",[],[])"#;
        let parsed = harmonia_store_aterm::parse_derivation_aterm(
            &store_dir,
            ca_drv,
            "ca-link".parse().unwrap(),
        )
        .unwrap();
        assert!(matches!(
            parsed.outputs[&on("bar")],
            harmonia_store_derivation::derivation::DerivationOutput::CAFloating(_)
        ));
        fs_err::write(store_dir.display(&sp("ca-link.drv")).to_string(), ca_drv).unwrap();
        write_ia_drv(&store_dir, "tail.drv", "bin", &sp("result"));
        let mut batches = Vec::new();
        let result = resolve_input_chains(
            &[chain("producer.drv", &["foo", "bar", "bin"])],
            |drv, output| resolve_from_drv_file(&store_dir, drv, output),
            |links| {
                batches.push(links.to_vec());
                assert_eq!(links, &[(sp("ca-link.drv"), on("bar"))]);
                vec![Some(sp("tail.drv"))]
            },
        );
        assert_eq!(result, vec![Some(sp("result"))]);
        assert_eq!(batches.len(), 1);
    }

    #[test]
    fn a_hundred_ca_inputs_use_one_database_batch() {
        let chains: Vec<_> = (0..100)
            .map(|n| chain(&format!("ca-{n}.drv"), &["out"]))
            .collect();
        let mut calls = 0;
        let result = resolve_input_chains(
            &chains,
            |_, _| None,
            |links| {
                calls += 1;
                assert_eq!(links.len(), 100);
                links.iter().map(|(drv, _)| Some(drv.clone())).collect()
            },
        );
        assert_eq!(calls, 1);
        assert_eq!(
            result,
            chains
                .into_iter()
                .map(|(path, _)| Some(path))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn shared_dynamic_prefix_is_queried_only_once() {
        let mut reads = Vec::new();
        let mut batch_sizes = Vec::new();
        let result = resolve_input_chains(
            &[
                chain("producer.drv", &["foo", "lib"]),
                chain("producer.drv", &["foo", "bin"]),
            ],
            |drv, output| {
                reads.push((drv.clone(), output.clone()));
                None
            },
            |links| {
                batch_sizes.push(links.len());
                links
                    .iter()
                    .map(|(drv, output)| {
                        if drv == &sp("producer.drv") {
                            assert_eq!(output, &on("foo"));
                            Some(sp("inner.drv"))
                        } else {
                            assert_eq!(drv, &sp("inner.drv"));
                            Some(sp(output.as_ref()))
                        }
                    })
                    .collect()
            },
        );
        assert_eq!(result, vec![Some(sp("lib")), Some(sp("bin"))]);
        assert_eq!(batch_sizes, vec![1, 2]);
        assert_eq!(reads.len(), 3);
    }

    #[test]
    fn shared_missing_prefix_stops_only_affected_chains() {
        let mut calls = 0;
        let result = resolve_input_chains(
            &[
                chain("missing.drv", &["foo", "lib"]),
                chain("missing.drv", &["foo", "bin"]),
                chain("valid.drv", &["out"]),
            ],
            |_, _| None,
            |links| {
                calls += 1;
                assert_eq!(links.len(), 2);
                links
                    .iter()
                    .map(|(drv, _)| (drv == &sp("valid.drv")).then(|| sp("valid")))
                    .collect()
            },
        );
        assert_eq!(calls, 1);
        assert_eq!(result, vec![None, None, Some(sp("valid"))]);
    }

    #[test]
    fn memo_is_shared_across_depths() {
        let mut calls = 0;
        let result = resolve_input_chains(
            &[chain("recursive.drv", &["foo", "foo"])],
            |_, _| None,
            |links| {
                calls += 1;
                assert_eq!(links, &[(sp("recursive.drv"), on("foo"))]);
                vec![Some(sp("recursive.drv"))]
            },
        );
        assert_eq!(result, vec![Some(sp("recursive.drv"))]);
        assert_eq!(calls, 1);
    }

    #[test]
    fn unreadable_or_invalid_drv_falls_back_to_database() {
        let temp = tempfile::tempdir().unwrap();
        let store_dir = StoreDir::new(temp.path().to_str().unwrap()).unwrap();
        fs_err::write(store_dir.display(&sp("invalid.drv")).to_string(), "broken").unwrap();
        let mut calls = 0;
        let result = resolve_input_chains(
            &[
                chain("absent.drv", &["out"]),
                chain("invalid.drv", &["out"]),
            ],
            |drv, output| resolve_from_drv_file(&store_dir, drv, output),
            |links| {
                calls += 1;
                vec![Some(sp("db-output")); links.len()]
            },
        );
        assert_eq!(calls, 1);
        assert_eq!(result, vec![Some(sp("db-output")); 2]);
    }

    #[test]
    fn harmonia_consumer_resolves_dynamic_and_opaque_inputs() {
        let store_dir = StoreDir::new("/nix/store").unwrap();
        let dynamic: SingleDerivedPath = format!("{}^foo^bar", sp("producer.drv")).parse().unwrap();
        let drv = Derivation {
            name: "consumer".parse().unwrap(),
            outputs: Default::default(),
            inputs: [dynamic, SingleDerivedPath::Opaque(sp("source"))]
                .into_iter()
                .collect(),
            platform: "x86_64-linux".into(),
            builder: "/bin/sh".into(),
            args: Vec::new(),
            env: Default::default(),
            structured_attrs: None,
        };
        let resolved = drv
            .try_resolve_force(&store_dir, &mut |inputs| {
                let chains: Vec<_> = inputs
                    .iter()
                    .map(|(path, output)| flatten_chain(path, output))
                    .collect();
                resolve_input_chains(
                    &chains,
                    |drv, output| match (drv.to_string().as_str(), output.as_ref()) {
                        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-producer.drv", "foo") => {
                            Some(sp("inner.drv"))
                        }
                        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-inner.drv", "bar") => Some(sp("result")),
                        _ => panic!("unexpected dynamic link"),
                    },
                    |_| panic!("all links are locally resolved"),
                )
            })
            .unwrap();
        assert_eq!(
            resolved.inputs,
            [sp("source"), sp("result")].into_iter().collect()
        );
    }

    fn cmp(a: &StepInfo, b: &StepInfo, sort_fn: StepSortFn) -> std::cmp::Ordering {
        a.sort_key(sort_fn).cmp(&b.sort_key(sort_fn))
    }

    fn create_test_step(
        highest_global_priority: i32,
        highest_local_priority: i32,
        lowest_build_id: BuildID,
        lowest_share_used: f64,
        rdeps_len: u64,
    ) -> StepInfo {
        let step = Step::new(
            StorePath::from_base_path("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test.drv").unwrap(),
            Arc::default(),
        );

        step.atomic_state
            .highest_global_priority
            .store(highest_global_priority, Ordering::Relaxed);
        step.atomic_state
            .highest_local_priority
            .store(highest_local_priority, Ordering::Relaxed);
        step.atomic_state
            .lowest_build_id
            .store(lowest_build_id, Ordering::Relaxed);
        step.atomic_state
            .rdeps_len
            .store(rdeps_len, Ordering::Relaxed);

        StepInfo {
            step,
            already_scheduled: false.into(),
            cancelled: false.into(),
            runnable_since: jiff::Timestamp::now(),
            lowest_share_used: lowest_share_used.into(),
        }
    }

    #[test]
    fn test_legacy_sort_key_global_priority() {
        let step1 = create_test_step(10, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::Legacy), Greater);
    }

    #[test]
    fn test_legacy_sort_key_share_used() {
        let step1 = create_test_step(5, 1, 1, 0.5, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::Legacy), Greater);
    }

    #[test]
    fn test_legacy_sort_key_local_priority() {
        let step1 = create_test_step(5, 10, 1, 1.0, 0);
        let step2 = create_test_step(5, 5, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::Legacy), Greater);
    }

    #[test]
    fn test_legacy_sort_key_build_id() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::Legacy), Greater);
    }

    #[test]
    fn test_legacy_sort_key_equal() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 1, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Equal);
    }

    #[test]
    fn test_rdeps_sort_key_global_priority() {
        let step1 = create_test_step(10, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }

    #[test]
    fn test_rdeps_sort_key_share_used() {
        let step1 = create_test_step(5, 1, 1, 0.5, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }

    #[test]
    fn test_rdeps_sort_key_rdeps_size() {
        let step1 = create_test_step(5, 1, 1, 1.0, 10);
        let step2 = create_test_step(5, 1, 2, 1.0, 5);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }

    #[test]
    fn test_rdeps_sort_key_local_priority() {
        let step1 = create_test_step(5, 10, 1, 1.0, 0);
        let step2 = create_test_step(5, 5, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }

    #[test]
    fn test_rdeps_sort_key_build_id() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 2, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }

    #[test]
    fn test_rdeps_sort_key_equal() {
        let step1 = create_test_step(5, 1, 1, 1.0, 0);
        let step2 = create_test_step(5, 1, 1, 1.0, 0);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Equal);
    }

    #[test]
    fn test_sort_fn_weight_only_for_rdeps() {
        // Same global priority, share used, local priority, and build ID
        // but a different rdeps_len. WithRdeps should order them, Legacy should not.
        let step1 = create_test_step(5, 1, 1, 1.0, 10);
        let step2 = create_test_step(5, 1, 1, 1.0, 5);

        assert_eq!(cmp(&step1, &step2, StepSortFn::Legacy), Equal);

        assert_eq!(cmp(&step1, &step2, StepSortFn::WithRdeps), Less);
        assert_eq!(cmp(&step2, &step1, StepSortFn::WithRdeps), Greater);
    }
}
