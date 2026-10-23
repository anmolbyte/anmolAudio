#!/usr/bin/env bash
# Tail OSLog output for the anmolAudio subsystem.
exec log stream --style compact --predicate 'subsystem == "app.anmol.anmolAudio"' --info
