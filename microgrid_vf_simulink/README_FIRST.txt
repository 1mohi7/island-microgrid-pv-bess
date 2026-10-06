FILES IN THIS PACKAGE
=====================

build_microgrid_vf_model.m
  Code that generates microgrid_vf_model.slx.

run_microgrid_vf_scenarios.m
  Current runner that reads <project>/matlab/results/optimizerResults.mat directly.

microgrid_vf_sfun.m
  Current dynamic model and scenario event logic.

HOW_TO_MODIFY_MODEL_AND_ADD_SCENARIOS.txt
  Exact modification and new-scenario instructions.

EXISTING_SCENARIOS_SHORT_DESCRIPTION.txt
  Short technical description of the five current simulations.

Recommended location:
  <project>/microgrid_vf_simulink/

Run build_microgrid_vf_model(true) to generate/open the .slx.
Run run_microgrid_vf_scenarios to execute the scenarios.
