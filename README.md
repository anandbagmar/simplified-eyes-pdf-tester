# Rothbury PDF Validation with Applitools ImageTester

## Objective

This utility makes it easy to validate PDF files with Applitools ImageTester across Windows, macOS, and Linux.

- INT is the baseline run.
- UAT is executed later and compared against the INT baseline in Applitools Eyes.
- Users only provide `-f` and may optionally use `--dry-run`.
- All other ImageTester options are read from the shared properties file.

## Prerequisites

- Java 17 or later available on `PATH`
- Internet access the first time the runner downloads the ImageTester jar
- A valid Applitools API key
- PDFs stored in the folder structure expected by ImageTester

## Setup

1. Open [config/imagetester.properties](/Users/anand.bagmar/projects/applitools/rothbury-pdf-testing/config/imagetester.properties).
2. Set `apiKey=YOUR_APPLITOOLS_API_KEY`, or leave `apiKey=` blank and use the `APPLITOOLS_API_KEY` environment variable instead.
3. Set the ImageTester defaults you want the script to use:
   - `appName=ImageTester`
   - `matchLevel=` to use the ImageTester default of `Strict`, or set a specific value like `Layout`
   - `ignoreDisplacements=false`
   - `accessibility=` unless you specifically want accessibility validation, for example `AA:WCAG_2_1`
   - `ignoreRegions=`
   - `contentRegions=`
   - `layoutRegions=`
4. Optionally set:
   - `serverUrl=https://eyesapi.applitools.com`
   - `proxy=http://proxy` or `proxy=http://proxy,user,pass`
5. Keep the `jars` folder in the repo root.
   If no ImageTester jar is present there, the script downloads the latest platform-specific release automatically.

Precedence:

- The script only accepts `-f`, `--dry-run`, and optional config-path overrides.
- `apiKey` comes from the properties file, then `APPLITOOLS_API_KEY` if present.
- If `serverUrl` is blank, the Applitools default server is used.

## Test Execution

Use the runner that matches your platform:

```bash
./run-imagetester.sh -f "/path/to/INT-batch-folder"
```

```bash
export APPLITOOLS_API_KEY="your-api-key"
./run-imagetester.sh -f "/path/to/INT-batch-folder"
```

```bash
./run-imagetester.sh --dry-run -f "/path/to/UAT-batch-folder"
```

```powershell
.\run-imagetester.ps1 -f "C:\ImageTester\SCTP-COMM-INT"
```

```powershell
$env:APPLITOOLS_API_KEY="your-api-key"
.\run-imagetester.ps1 -f "C:\ImageTester\SCTP-COMM-INT"
```

```bat
run-imagetester.bat -f "C:\ImageTester\SCTP-COMM-UAT"
```

Typical flow:

1. Run INT first to create the baseline.
2. Run UAT later using the equivalent target folder structure.
3. Review the comparison results in the Applitools dashboard link shown in the console summary.

Useful ImageTester settings in the properties file:

- `appName`
- `matchLevel`
- `ignoreDisplacements`
- `accessibility`
- `ignoreRegions`
- `contentRegions`
- `layoutRegions`

For accessibility, only set a value when you want accessibility validation enabled.
When used, keep values like `AA:WCAG_2_1` in the properties file.
The runner expands that into the two-part `-ac` argument format expected by ImageTester `3.9.1`.

Notes:

- `-os` is added automatically as `Windows`, `Linux`, or `Mac OSX`.
- `-ap pdf` is always added automatically.
- If a jar already exists in the root `jars` folder, the runner uses it and does not download another one.
- `--dry-run` shows the resolved Java command and exits without running ImageTester.

## Test Results

After execution, the runner prints a short summary showing:

- the jar used
- the target folder
- the config file used
- the log file path
- the process exit code
- the Applitools dashboard URL when one is found in the output

Detailed console output is also written to the `logs` folder for troubleshooting and auditability.

## Contact

Update this section with your team’s preferred support contact before sharing widely.

- Owner: Rothbury QA / Automation Team
- Support: Add your email address or Teams channel here
