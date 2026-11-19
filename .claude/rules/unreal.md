# Unreal Engine / C++
- Confirm `.uproject`, engine version, target platform, and build configuration before recommending commands.
- Inspect existing `UCLASS`, `UFUNCTION`, subsystems, interfaces, and Blueprint integration before adding types.
- Respect Unreal reflection, module dependencies, object lifetime, garbage collection, threading, and game-thread requirements.
- Check `.Build.cs`, plugins, and asset references before changing dependencies.
- Prefer relevant Unreal Automation Tests, functional tests, and reproducible gameplay steps; don't claim Blueprint behavior is validated by C++ compilation.
- Ask approval before UnrealBuildTool, UAT, editor, cook, or package commands that write generated files.
- Avoid manually editing generated headers, `Intermediate/`, or `Binaries/`.
