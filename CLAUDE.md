# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Development Commands

```bash
# Install dependencies
fvm flutter pub get

# Run the app (iOS simulator)
fvm flutter run

# Build iOS release
fvm flutter build ios --release

# Run static analysis
fvm flutter analyze

# Run tests
fvm flutter test

# Run a single test file
fvm flutter test test/widget_test.dart
```

## Project Scripts

### Initialize pubspec.yaml from template

```bash
# Reset pubspec.yaml to template state (removes secondary module dependencies)
./scripts/init_pubspec.sh
```

### Sync secondary module code

```bash
# First time: generate config file template
./scripts/sync_secondary.sh --init-config

# Edit config file to set project paths
vim scripts/sync_secondary.conf

# Sync using config file paths
./scripts/sync_secondary.sh -p ph      # Sync pornhub_app project
./scripts/sync_secondary.sh -p hjsq    # Sync hjsq project
./scripts/sync_secondary.sh -p md      # Sync md project
./scripts/sync_secondary.sh -p tiktok  # Sync tiktok project
./scripts/sync_secondary.sh -p 91cg    # Sync 91cg project
./scripts/sync_secondary.sh -p yms     # Sync yms project

# Override path from command line
./scripts/sync_secondary.sh -p ph -s /path/to/pornhub_app

# Dry run (preview without changes)
./scripts/sync_secondary.sh -p ph -d

# List configured projects
./scripts/sync_secondary.sh -l

# Show help
./scripts/sync_secondary.sh -h
```

### Create project (if available)

```bash
# Initialize a new project with custom name/package
./scripts/create_ab_project.sh -n app_name -p com.example.app -d "Display Name"
```

### Code obfuscation

```bash
# 统一入口 obfuscate_code.sh，多种组合
./scripts/obfuscate_code.sh --all              # 全部混淆
./scripts/obfuscate_code.sh --string          # 字符串混淆
./scripts/obfuscate_code.sh --callstack       # 调用栈混淆
./scripts/obfuscate_code.sh -p ph --bloat     # 文件膨胀（4.3a）
./scripts/obfuscate_code.sh -p ph --bloat --noise --mutation --symbols  # 膨胀 + 扩展
```

详见 [docs/OBFUSCATION_BLOAT.md](docs/OBFUSCATION_BLOAT.md)

### 机审模拟检验

```bash
# 单包检验（敏感字符串、框架、资源）
./scripts/verify_review_simulator.sh single build/ios/ipa/MyApp.ipa

# 双包相似度（模拟 4.3a）
./scripts/verify_review_simulator.sh compare app1.ipa app2.ipa
```

详见 [docs/REVIEW_VERIFICATION.md](docs/REVIEW_VERIFICATION.md)

### Framework obfuscation (rename + mutate)

```bash
# One-shot: rename + mutate + pub get + pod install
./scripts/obfuscate_frameworks.sh run

# List renameable B-side iOS plugins
./scripts/obfuscate_frameworks.sh list

# Generate rename mapping only
./scripts/obfuscate_frameworks.sh -g

# Apply rename mapping only
./scripts/obfuscate_frameworks.sh apply

# Mutate only (inject/transform native code in plugins/)
./scripts/obfuscate_frameworks.sh mutate --seed com.myapp.bundle

# Clean injected mutation files
./scripts/obfuscate_frameworks.sh clean

# Dry run (preview without modifying)
./scripts/obfuscate_frameworks.sh run -d -v
```

## Architecture

This is a Flutter template for iOS App Store submission. The app displays different UIs (primary vs secondary) based on remote configuration.

### Core Flow

1. **Startup**: `SplashPage` initializes `ConfigService` which fetches remote config
2. **Routing**: `AppRouter.generateRoute()` checks `ConfigService.isSecondaryMode` to decide which UI to show
3. **Foreground Refresh**: `ConfigService` fetches remote config when app resumes from background

### Key Components

- **ConfigService** (`lib/services/config_service.dart`): Singleton service that fetches `{enable_secondary: bool}` from `EnvConfig.apiBaseUrl/api/app-config`. Falls back to primary mode on network failure.

- **AppRouter** (`lib/router/app_router.dart`): Dynamic router that returns either `HomePage` or `ModuleEntry.getHomePage()` based on config state.

- **ModuleEntry** (`lib/modules/secondary/module_entry.dart`): Unified entry point for secondary module. When syncing code from external repo, this interface must be preserved.

### Module Separation

- `lib/modules/primary/`: Primary mode (review-facing) - develop freely for App Store approval
- `lib/modules/secondary/`: Secondary mode (business) - synced from external repo via `sync_secondary.sh`, do not modify directly

### Configuration

- `lib/config/app_config.dart`: App name, debug mode, silent period settings
- `lib/config/env_config.dart`: Environment-specific API base URLs (dev/staging/prod)
