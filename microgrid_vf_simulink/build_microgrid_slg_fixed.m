function build_microgrid_slg_fixed()
%BUILD_MICROGRID_SLG_FIXED
% Creates a visible microgrid single-line diagram in Simulink.
%
% RUN:
%   build_microgrid_slg_fixed
%
% OUTPUT:
%   microgrid_slg.slx
%
% NOTE:
% This is a graphical SLG for presentation/documentation.
% Your existing microgrid_vf_model.slx remains the dynamic V/f model.

model = 'microgrid_slg';

%% ------------------------------------------------------------------------
% Save the generated SLX beside this .m file

thisFile = mfilename('fullpath');
thisFolder = fileparts(thisFile);

if isempty(thisFolder)
    thisFolder = pwd;
end

outputFile = fullfile(thisFolder,[model '.slx']);

%% ------------------------------------------------------------------------
% Remove old generated model

if bdIsLoaded(model)
    close_system(model,0);
end

if isfile(outputFile)
    delete(outputFile);
end

%% ------------------------------------------------------------------------
% Create model

new_system(model);
open_system(model);

set_param(model, ...
    'SolverType','Fixed-step', ...
    'StopTime','1', ...
    'Location',[50 50 1550 850]);

%% ========================================================================
% MAIN GRID PATH

addVisualBlock(model,'11 kV Grid', ...
    [60 210 180 270],0,1);

addVisualBlock(model,'PCC MID Breaker', ...
    [245 210 385 270],1,1);

addVisualBlock(model,'11kV-400V Transformer', ...
    [450 200 635 280],1,1);

% 4 inputs: Grid, PV, BESS, Diesel
% 2 outputs: non-critical branch and critical branch
addVisualBlock(model,'400 V Main Bus', ...
    [720 185 885 295],4,2);

add_line(model, ...
    '11 kV Grid/1', ...
    'PCC MID Breaker/1', ...
    'autorouting','on');

add_line(model, ...
    'PCC MID Breaker/1', ...
    '11kV-400V Transformer/1', ...
    'autorouting','on');

add_line(model, ...
    '11kV-400V Transformer/1', ...
    '400 V Main Bus/1', ...
    'autorouting','on');

%% ========================================================================
% PV BRANCH

addVisualBlock(model,'PV Array', ...
    [250 365 370 425],0,1);

addVisualBlock(model,'PV GFL Inverter', ...
    [480 365 625 425],1,1);

add_line(model, ...
    'PV Array/1', ...
    'PV GFL Inverter/1', ...
    'autorouting','on');

add_line(model, ...
    'PV GFL Inverter/1', ...
    '400 V Main Bus/2', ...
    'autorouting','on');

%% ========================================================================
% BESS BRANCH

addVisualBlock(model,'BESS', ...
    [250 500 370 560],0,1);

addVisualBlock(model,'BESS GFM Inverter', ...
    [480 500 625 560],1,1);

add_line(model, ...
    'BESS/1', ...
    'BESS GFM Inverter/1', ...
    'autorouting','on');

add_line(model, ...
    'BESS GFM Inverter/1', ...
    '400 V Main Bus/3', ...
    'autorouting','on');

%% ========================================================================
% DIESEL BRANCH

addVisualBlock(model,'Diesel Generator', ...
    [480 640 625 700],0,1);

add_line(model, ...
    'Diesel Generator/1', ...
    '400 V Main Bus/4', ...
    'autorouting','on');

%% ========================================================================
% NON-CRITICAL LOAD BRANCH

addVisualBlock(model,'Non-Critical Load', ...
    [1000 115 1160 180],1,0);

add_line(model, ...
    '400 V Main Bus/1', ...
    'Non-Critical Load/1', ...
    'autorouting','on');

%% ========================================================================
% CRITICAL LOAD / ISLANDING BRANCH

addVisualBlock(model,'Islanding Breaker', ...
    [975 300 1125 360],1,1);

addVisualBlock(model,'400 V Critical Bus', ...
    [1200 295 1360 365],1,1);

addVisualBlock(model,'Critical Load 0.3 MW', ...
    [1430 295 1585 365],1,0);

add_line(model, ...
    '400 V Main Bus/2', ...
    'Islanding Breaker/1', ...
    'autorouting','on');

add_line(model, ...
    'Islanding Breaker/1', ...
    '400 V Critical Bus/1', ...
    'autorouting','on');

add_line(model, ...
    '400 V Critical Bus/1', ...
    'Critical Load 0.3 MW/1', ...
    'autorouting','on');

%% ========================================================================
% ADD TEXT USING BLOCK NAMES ONLY
% Avoids the Simulink.Annotation/set_param error from the previous script.

add_block('built-in/Note', ...
    [model '/TITLE'], ...
    'Position',[60 35 700 95]);

set_param([model '/TITLE'], ...
    'Name','MICROGRID SLG - 11 kV GRID | 400 V BUS | 50 Hz');

add_block('built-in/Note', ...
    [model '/MODE NOTE'], ...
    'Position',[980 450 1540 555]);

set_param([model '/MODE NOTE'], ...
    'Name',sprintf(['NORMAL: grid supplies/imports/exports with PV, BESS and diesel connected.\n' ...
                   'ISLANDED: PCC/MID isolates the utility grid and non-critical load is shed.\n' ...
                   'Critical load remains on PV + BESS + diesel, subject to available power.']));

%% ------------------------------------------------------------------------
% Make labels easier to read

blocks = find_system(model,'SearchDepth',1,'Type','Block');

for k = 1:numel(blocks)
    if strcmp(blocks{k},model)
        continue;
    end

    try
        set_param(blocks{k},'FontSize','11');
    catch
        % Some note/block types do not expose FontSize; ignore safely.
    end
end

%% ------------------------------------------------------------------------
% Save and open

save_system(model,outputFile);

fprintf('\nCreated successfully:\n%s\n\n',outputFile);
fprintf('The visible SLG should now be open in Simulink.\n');

open_system(model);

end


%% =========================================================================
function addVisualBlock(model,name,position,nInputs,nOutputs)
%ADDVISUALBLOCK Create a simple subsystem with visible ports.
%
% Uses built-in Simulink blocks rather than library paths, making the
% generator less dependent on release-specific Library Browser locations.

block = [model '/' name];

add_block('built-in/Subsystem', ...
    block, ...
    'Position',position);

% Remove the default contents of the new subsystem.
Simulink.SubSystem.deleteContents(block);

%% Add inputs
for k = 1:nInputs
    y = 25 + (k-1)*35;

    add_block('built-in/Inport', ...
        sprintf('%s/In%d',block,k), ...
        'Port',num2str(k), ...
        'Position',[25 y 55 y+16]);
end

%% Add outputs
for k = 1:nOutputs
    y = 25 + (k-1)*35;

    add_block('built-in/Outport', ...
        sprintf('%s/Out%d',block,k), ...
        'Port',num2str(k), ...
        'Position',[225 y 255 y+16]);
end

%% Internal placeholder logic

% Source component
if nInputs == 0 && nOutputs > 0

    add_block('built-in/Constant', ...
        [block '/Source'], ...
        'Value','0', ...
        'Position',[105 40 135 70]);

    for k = 1:nOutputs
        add_line(block, ...
            'Source/1', ...
            sprintf('Out%d/1',k), ...
            'autorouting','on');
    end

% Load/sink component
elseif nInputs > 0 && nOutputs == 0

    for k = 1:nInputs
        add_block('built-in/Terminator', ...
            sprintf('%s/Terminator%d',block,k), ...
            'Position',[150 22+(k-1)*35 170 42+(k-1)*35]);

        add_line(block, ...
            sprintf('In%d/1',k), ...
            sprintf('Terminator%d/1',k), ...
            'autorouting','on');
    end

% One-input pass-through component
elseif nInputs == 1 && nOutputs > 0

    for k = 1:nOutputs
        add_line(block, ...
            'In1/1', ...
            sprintf('Out%d/1',k), ...
            'autorouting','on');
    end

% Multi-input bus
elseif nInputs > 1 && nOutputs > 0

    add_block('built-in/Sum', ...
        [block '/BusJunction'], ...
        'Inputs',repmat('+',1,nInputs), ...
        'Position',[110 35 140 35+30*nInputs]);

    for k = 1:nInputs
        add_line(block, ...
            sprintf('In%d/1',k), ...
            sprintf('BusJunction/%d',k), ...
            'autorouting','on');
    end

    for k = 1:nOutputs
        add_line(block, ...
            'BusJunction/1', ...
            sprintf('Out%d/1',k), ...
            'autorouting','on');
    end
end

end
