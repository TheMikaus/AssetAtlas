# Playdate (Lua / SDK)
- Inspect project layout, SDK version, Lua modules, assets, and build scripts before commands.
- Respect Playdate's 400×240 monochrome (1-bit) display and memory/performance constraints.
- Check crank position/docked behavior, buttons, frame timing, and simulator-vs-device differences when relevant.
- Validate drawing with 1-bit assets/dithering; don't assume grayscale support.
- Prefer SDK compiler/simulator smoke tests and explicit on-device checks for hardware-dependent behavior.
- Ask approval before compiling or packaging if generated files will change.
