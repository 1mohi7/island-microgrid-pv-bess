function modelPath = build_microgrid_vf_model(openAfterBuild)
%BUILD_MICROGRID_VF_MODEL Generate the Simulink .slx used by the V/f scenarios.
%
%   build_microgrid_vf_model
%       Rebuilds microgrid_vf_model.slx beside this .m file.
%
%   build_microgrid_vf_model(true)
%       Rebuilds the model and leaves it open in Simulink.
%
% IMPORTANT MODEL BOUNDARY
% ------------------------
% This is a reduced-order, average-value V/f demonstration model. The
% electrical/control dynamics are implemented in microgrid_vf_sfun.m.
% The generated .slx is the Simulink shell that executes that S-function,
% logs its 16 output signals, and provides a live scope.
%
% It is suitable for islanding, source/load disturbance, and
% resynchronization demonstrations. It is NOT an EMT/switching model and
% should not be used for fault-current or critical-clearing-time studies.

if nargin < 1
    openAfterBuild = false;
end

mdl = 'microgrid_vf_model';
scriptDir = fileparts(mfilename('fullpath'));
modelPath = fullfile(scriptDir,[mdl '.slx']);

% The Level-2 MATLAB S-function must be visible to Simulink.
addpath(scriptDir);
sfunPath = fullfile(scriptDir,'microgrid_vf_sfun.m');
if ~isfile(sfunPath)
    error('Required S-function is missing: %s',sfunPath);
end

% Close/remove an older generated copy so this script is the single source
% of truth for the .slx layout.
if bdIsLoaded(mdl)
    close_system(mdl,0);
end
if isfile(modelPath)
    delete(modelPath);
end

new_system(mdl);

% ---------------------------------------------------------------------
% Simulation configuration.
% The scenario runner overrides StopTime separately for every scenario.
set_param(mdl, ...
    'SolverType','Fixed-step', ...
    'Solver','FixedStepDiscrete', ...
    'FixedStep','0.001', ...
    'StopTime','6', ...
    'SaveTime','on', ...
    'ReturnWorkspaceOutputs','on');

% ---------------------------------------------------------------------
% Core reduced-order microgrid model.
% SC is assigned to the MATLAB base workspace by run_microgrid_vf_scenarios.
core = [mdl '/400 V Equivalent Microgrid Dynamics'];
add_block('simulink/User-Defined Functions/Level-2 MATLAB S-Function',core, ...
    'FunctionName','microgrid_vf_sfun', ...
    'Position',[190 150 495 245]);

% Save all 16 outputs as one timeseries named microgridY.
sink = [mdl '/Logged V-f and Power Signals'];
add_block('simulink/Sinks/To Workspace',sink, ...
    'VariableName','microgridY', ...
    'SaveFormat','Timeseries', ...
    'Position',[630 150 835 205]);

% Live view while the simulation is running.
scope = [mdl '/Live Scope'];
add_block('simulink/Sinks/Scope',scope, ...
    'Position',[630 275 835 340]);

add_line(mdl, ...
    '400 V Equivalent Microgrid Dynamics/1', ...
    'Logged V-f and Power Signals/1', ...
    'autorouting','on');
add_line(mdl, ...
    '400 V Equivalent Microgrid Dynamics/1', ...
    'Live Scope/1', ...
    'autorouting','on');

% Documentation shown on the model canvas. The source/load elements below
% are represented mathematically inside microgrid_vf_sfun.m rather than as
% detailed switching devices.
Simulink.Annotation(mdl, sprintf([ ...
    'MICROGRID DYNAMIC DEMONSTRATION MODEL\n' ...
    'Equivalent three-phase bus: 400 V line-line, 50 Hz\n\n' ...
    'Internally represented elements:\n' ...
    '  Utility grid + PCC | PV (grid-following) | BESS (grid-forming in island)\n' ...
    '  Diesel generator | Critical load | Non-critical load\n\n' ...
    'Scenario data are supplied through base-workspace struct SC.\n' ...
    'run_microgrid_vf_scenarios.m creates SC from the optimizer result.']));

Simulink.Annotation(mdl, sprintf([ ...
    'OUTPUT VECTOR (microgridY)\n' ...
    '1 f | 2 V | 3 Grid P | 4 PV P | 5 BESS P | 6 Diesel P\n' ...
    '7 Critical load | 8 Non-critical load | 9 Total load | 10 Total generation\n' ...
    '11 Phase error | 12 PCC state | 13 PV available | 14 BESS GFM\n' ...
    '15 Diesel active | 16 Non-critical connected']));

save_system(mdl,modelPath);

if openAfterBuild
    open_system(modelPath);
else
    close_system(mdl,0);
end

fprintf('Generated Simulink model:\n  %s\n',modelPath);
fprintf('Run run_microgrid_vf_scenarios.m to execute the existing scenarios.\n');
end
