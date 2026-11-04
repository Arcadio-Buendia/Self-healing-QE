# Self Healing DFT

Portable Quantum ESPRESSO pw.x runner with bounded TypeSafe remediation.

## Run

Install Bash, Python 3, curl, and Quantum ESPRESSO. Put your QE `*.in` files and requisite pseudopotentials in a working folder. Their `pseudo_dir`, `outdir`, and other referenced paths must resolve on the current machine. The runner executes each supplied input as written; SCF/SOC settings, pseudopotential suitability, geometry, cutoffs and k-points remain the input author's responsibility. It does not generate a separate SOC stage.

Set TYPESAFE_API_KEY in the environment or in `.env` in the working folder (see `.env.example`). Then, from that folder:

```bash
bash "/path/to/Self Healing DFT/run_scf_soc_autonomous.sh"
# Or select local input filenames:
bash "/path/to/Self Healing DFT/run_scf_soc_autonomous.sh" sample.in
# Background execution:
bash "/path/to/Self Healing DFT/launch_autonomous.sh" sample.in
```

Defaults: one core, one k-point pool, 15 calculation attempts per input. Set EXEC_CORES, POOLS, MAX_HEAL_ATTEMPTS, PW_BIN, MPI_BIN, QE_ENV_FILE or RULES_FILE as needed. MPI is required for EXEC_CORES > 1; POOLS must divide EXEC_CORES. Use your scheduler allocation when running on a cluster. PREFLIGHT=1 opts into proactive parameter changes; disabled by default. API requests send the input, output excerpt and remediation history to TypeSafe.

Inputs are edited in place during remediation: keep originals separately. Outputs are `<input-stem>.out`; previous outputs are overwritten on retry. Successful outputs containing JOB DONE without convergence NOT achieved are skipped on subsequent runs. Delete or rename an old output before rerunning a changed input. All QE scratch/save data are retained at the input's configured paths. Exit status is nonzero if any calculation fails. A directory lock prevents overlapping runners; after an unclean kill, verify no runner remains before removing `.self_healing_dft.lock`.

## Workflow behavior

The runner discovers input filenames in the working directory, accepts executable and environment overrides, and retains calculation scratch data. Default rules exclude convergence-threshold relaxation and smearing-width changes. Numerical remedies require validation for the supplied calculation.

Runtime remediation history and journals are generated automatically and excluded from Git. Credentials, calculation inputs, pseudopotentials and results should be kept in calculation directories outside this code checkout.

Validation uses mocked pw.x and API responses; a real calculation requires a configured QE installation, inputs, pseudopotentials and a live TypeSafe account. No real DFT result is claimed.
