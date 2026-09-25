Minimal stand-ins for the Flycast headers that the Leaf account bridge
(core/achievements/ra_account_bridge.cpp) and the configuration store
(core/cfg/cfg.cpp, core/cfg/ini.cpp) include, so scripts/ra-account-fault-test.sh
can compile those three REAL files on the host and inject faults under them.

Only what the bridge and the store use is declared. Everything else
(rcheevos, ImGui, the emulator) stays out: the fault fixture exercises the
bridge's file and state handling, not the network login itself, which the
probe simulates through the same entry points achievements.cpp calls.
