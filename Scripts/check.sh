#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
SDK="${FREIGHT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
mkdir -p .build/module-cache Verification
COMMON=(-O -swift-version 5 -parse-as-library -sdk "$SDK" -module-cache-path .build/module-cache)
xcrun swiftc "${COMMON[@]}" Sources/Model.swift Sources/Core.swift Tests/CoreTests.swift -o .build/CoreTests
.build/CoreTests > Verification/core-tests.json
xcrun swiftc "${COMMON[@]}" Sources/Model.swift Sources/Core.swift Sources/SolverAdapter.swift Tests/SolverAdapterTests.swift -o .build/SolverAdapterTests
.build/SolverAdapterTests Vendor/bin/vroom > Verification/solver-adapter-checks.json
xcrun swiftc "${COMMON[@]}" -DPIPELINE_TEST_STUB Sources/Model.swift Sources/Core.swift Sources/Roads.swift Sources/Pipeline.swift Tests/PipelineTests.swift -o .build/PipelineTests
.build/PipelineTests > Verification/pipeline-tests.json
xcrun swiftc "${COMMON[@]}" -DTRANSFER_TEST_STUB Sources/Model.swift Sources/Core.swift Sources/Roads.swift Sources/Transfer.swift Tests/TransferTests.swift -o .build/TransferTests
.build/TransferTests > Verification/transfer-run.log
xcrun swiftc "${COMMON[@]}" Sources/Model.swift Sources/Core.swift Sources/Roads.swift Tests/RoadTests.swift -o .build/RoadTests
.build/RoadTests > Verification/road-tests.json
echo 'All local checks passed. Public network and installed UI require separate checks.'
