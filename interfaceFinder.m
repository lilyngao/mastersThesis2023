% ------------------------------------------------------------------------
%                       miniDLW INTERFACE FINDER
% ------------------------------------------------------------------------
% Find and move to position of glass-resist interface in preparation for
% laser writing.
%
% User must navigate to the approximate position of the interface prior to
% running this script. This can be achieved by adjusting the z piezo
% position using the controller knob and viewing the camera footage via
% FlyCamera2.
%
% N.B. Laser diode power supply must be turned on manually prior to running
% this script.
%
% Version 1: 15.05.2023 LG
% Version 2: 25.05.2023 LG, changed image acq method
% Version 3: 06.06.2023 LG, changed camera settings
% Version 4: 12.06.2023 LG, added hard coded evaluation methods
% Version 5: 16.06.2023 LG, removed extra eval methods, added fine scan

close all
clear all

tic
%% USER INPUT

% Exposure time aka "shutter speed"
exposureTime = 3.5;          % ms % Assuming OD2 filter is used
% Total distance to sweep through, must be even number
range = 2000;               % nm
% Coarse step size, should be divisible by total distance
coarseStepSize = 50;       % nm
% Fine step size
fineStepSize = 10; % nm
% Fine range
fineRange = 400; % nm
% Lowest global brightness maximum allowed by the interface finder
minBrightness = 80;
% Highest global brightness maximum allowed by the interface finder
maxBrightness = 200;
% Define percentage of global maximum brightness as threshold
threshFactor = 0.6;
% Define ROI for figures such that they are zoomed into the focus
figROI = [79 70 45 45];

% For development:
isDevel = 1;
% Show figures
showFigs = 0;
% Show stats
showStats = 1;
% Stage wait time to allow settling
stageWaitTime = 0.05; % s
% Colour channel to use
colourIdx = 3; % blue
% Number of frames per trigger
framesPerTrig = 1;
% Region of interest
ROI = [200 400 202 208];    % [XOffset YOffset Width Height]
% Pixel size
pixelSize = 4.800; % um
% Save directory
pathStr = '\\aph702s01.aph.kit.edu\datenwegener$\MiniDLW\07 Measurements';

%% ROUTINE

% Initialze z stage and ucontroller
teensy = serialport('COM7',115200);
piezo = serialport('COM10',460800);
% Change the terminator for the piezo connection so "readline" can be
% used
configureTerminator(piezo,'CR')

% Set stage dynamics. See manual for more information.
writeline(piezo, 'Y8=2000');
writeline(piezo, 'Y9=4750');
writeline(piezo, 'Y10=1200');
writeline(piezo, 'Y65=8');
writeline(piezo, 'Y66=4');
writeline(piezo, 'Y67=18');

% Preallocate cell array to contain coarse image data
numSteps = range/coarseStepSize + 1; % Plus 1 for 0 position
startPoint = range/2;
% Create string array with z positions
positionNum = linspace(-startPoint,startPoint,numSteps)';
positionStr = string(positionNum);

% Preallocate cell array to contain fine image data
numStepsFine = fineRange/fineStepSize + 1; % Plus 1 for 0 position
startPointFine = fineRange/2;
% Create string array with z positions
positionNumFine = linspace(-startPointFine,startPointFine,numStepsFine)';
positionStrFine = string(positionNumFine);

% Initialize camera (code taken from measureFocus)
cam = videoinput('pointgrey', 1, 'F7_RGB_1280x1024_Mode0');  % Chameleon3
src = getselectedsource(cam);

% Set camera settings
cam.ROIPosition = ROI;
% Set trigger config to manual as to reduce overhead
triggerconfig(cam, 'manual');
cam.FramesPerTrigger = framesPerTrig;
cam.TriggerRepeat = numSteps-1;
cam.TriggerFrameDelay = 3; % Skip the 1st 3 frames to avoid errors
src.Brightness = 0;
% Set modes to manual to maintain full control
src.Exposure = -5.585; % maybe this line is redundant
src.Gain = 0;               % dB
src.ExposureMode = 'Off';
src.FrameRateMode = 'Off';
src.ShutterMode = 'Manual';
src.GainMode = 'Manual';
src.Shutter = exposureTime;      % in ms; min is 0.01 ms

% For neat figures, generate axis labels
ROI = cam.ROIPosition;
xl = linspace(0,ROI(3)*pixelSize);
yl = linspace(0,ROI(4)*pixelSize);

% Turn laser on to threshold current
fprintf(teensy,'LP 7.0');
disp('Laser on at 7%')

% Define the figure settings
if showFigs
    zArr = figure('visible','off','units','normalized',...
        'outerposition',[0 0 0.5 1],'Name','Slice Images Summary');
end
if showStats
    f1 = figure('visible','off','units','normalized',...
        'outerposition',[0.5 0 0.5 1],'Name','Interface Finder Summary');
end
disp('Starting interface finder...')

% Debugging variables
debugCounter = 1;
debugMaxVal = [];
debugInterfacePos = [];
debugStageCounter = 1;

% Query stage position before starting routine
stagePos(debugStageCounter) = getStagePosition(piezo); % nm
debugStageCounter = debugStageCounter + 1;

% Pre-set boolean for fine scan
useFineSteps = 0;
% Pre-set boolean for the coarse while loop
isComplete = 0;

% Main loop
while ~isComplete
    % Get current stage position
    startZPos = getStagePosition(piezo);
    % Create array for stage positions
    stagePosArr = linspace(startZPos-startPoint,startZPos+startPoint,numSteps);
    % Move down by half of the total z distance to start at bottom
    disp(join(['Moving to -',num2str(startPoint),' nm']))
    writeline(piezo, ['T',num2str(stagePosArr(1)/10)]);
    pause(stageWaitTime)
    stagePos(debugStageCounter) = getStagePosition(piezo); % nm
    debugStageCounter = debugStageCounter + 1;

    % Pre allocations for camera acquisition
    isLog = 1;
    zImages = cell(1,numSteps);
    maxVal = NaN(1,numSteps);
    start(cam)
    % Step through the z positions from bottom to top, save only blue channel
    for idx = 1:1:numSteps
        disp(join(['Imaging at ',positionStr(idx),' nm']))
        tic
        trigger(cam)
        while isLog
            isLog = islogging(cam);
        end
        camTiming(idx) = toc;
        isLog = 1;

        if idx ~= numSteps % Do not move if at the last iteration
            writeline(piezo, ['T',num2str(stagePosArr(idx+1)/10)]);
            pause(stageWaitTime)
            stagePos(debugStageCounter) = getStagePosition(piezo); % nm
            debugStageCounter = debugStageCounter + 1;
        end

        % Retrieve data from the camera
        zImages3_frames = getdata(cam);
        % Already remove unexplained noise at the edges
        zImages{idx} = zImages3_frames(5:ROI(3)-5,5:ROI(4)-5,colourIdx);
        % Calculate maximum pixel brightness
        maxVal(idx) = max(zImages{idx},[],'all');
    end

    if isDevel
        debugMaxVal(debugCounter,:) = maxVal;
        debugExpTime(debugCounter,:) = src.Shutter;
    end

    % Compensate for the fluctuations in image brightness
    if max(maxVal) <  minBrightness
        currentExpTime = src.Shutter;      % in ms; min is 0.01 ms
        src.Shutter = currentExpTime*1.5;
        disp(join(['Maximum brightness too low, change exposure time from ',...
            num2str(currentExpTime),' ms to ',...
            num2str(currentExpTime*1.5),' ms.']))
        % Move to original start position
        disp(join(['Moving back to ',num2str(startZPos),' nm']))
        writeline(piezo, ['T',num2str(startZPos/10)]);
        pause(stageWaitTime)
        stagePos(debugStageCounter) = getStagePosition(piezo); % nm
        debugStageCounter = debugStageCounter + 1;
        continue
    elseif max(maxVal) > maxBrightness
        currentExpTime = src.Shutter;      % in ms; min is 0.01 ms
        src.Shutter = currentExpTime*0.5;
        disp(join(['Maximum brightness too high, change exposure time from ',...
            num2str(currentExpTime),' ms to ',...
            num2str(currentExpTime*0.5),' ms.']))
        % Move to original start position
        disp(join(['Moving back to ',num2str(startZPos),' nm']))
        writeline(piezo, ['T',num2str(startZPos/10)]);
        pause(stageWaitTime)
        stagePos(debugStageCounter) = getStagePosition(piezo); % nm
        debugStageCounter = debugStageCounter + 1;
        continue
    end

    % Apply evaluation method
    thresholdVal = max(maxVal)*threshFactor;
    sumOfPixelsAboveThreshold = NaN(1,numSteps);
    for idxTh = 1:1:numSteps
        tempData = zImages{idxTh};
        sumOfPixelsAboveThreshold(idxTh) = ...
            sum(tempData(tempData>thresholdVal),'all');
    end
    % Detemine index of interface slice
    [~,interfaceIdx] = max(sumOfPixelsAboveThreshold);
    interfacePosAbs = stagePosArr(interfaceIdx);
    interfacePos = positionNum(interfaceIdx);

    if isDevel
        debugInterfacePos(debugCounter) = interfacePos;
        interfaceImages{debugCounter} = zImages{interfaceIdx};
        allImages{debugCounter} = zImages;
    end

    % Navigate to interface position after formatting the command string
    disp(join(['Moving to interface at ',num2str(interfacePos),...
        ' nm. Setting as new 0 nm position.']))
    newPosStr = ['T',num2str(interfacePosAbs/10)];
    writeline(piezo, newPosStr);
    pause(stageWaitTime)
    stagePos(debugStageCounter) = getStagePosition(piezo); % nm
    debugStageCounter = debugStageCounter + 1;

    if isDevel
        debugCounter = debugCounter + 1;
    end

    if showFigs
        for idxPlot = 1:1:numSteps
            figure(zArr)
            subplot(5,ceil(numSteps/5),idxPlot)
            image(zImages{idxPlot}(figROI(2):figROI(2)+figROI(4),...
                figROI(1):figROI(1)+figROI(3))) % zoom in
            set(gca, 'XTickLabel', [])
            set(gca, 'YTickLabel', [])
            axis image
            title(join([num2str(positionNum(idxPlot)),' nm']))
        end
    end

    if showStats
        % Plot data and get user response on whether to continue
        figure(f1)
        subplot(4,1,1)
        plot(positionNum,sumOfPixelsAboveThreshold)
        grid on
        xlabel('Relative Z Position (nm)')
        ylabel(join(['Sum of pixels above threshold brightness of ',...
            num2str(thresholdVal)]))
        hold on
        % Indicate the interface position
        interfaceIndicator = NaN(numSteps,1);
        interfaceIndicator(interfaceIdx) =...
            sumOfPixelsAboveThreshold(interfaceIdx);
        plot(positionNum,interfaceIndicator,'ro')
        legend('',join([num2str(interfacePos),' nm']))
        hold off
        subplot(4,1,2)
        plot(positionNum,maxVal)
        grid on
        xlabel('Relative Z Position (nm)')
        ylabel('Maximum brightness values')
        subplot(4,1,3)
        plot(positionNum,camTiming)
        grid on
        xlabel('Relative Z Position (nm)')
        ylabel('Acquisition time (s)')
        subplot(4,1,4)
        plot(stagePos)
        grid on
        xlabel('Data points')
        ylabel('Stage position (nm)')
    end
    answer = questdlg('Exit interface finder?','','Fine Scan','Repeat',...
        'Exit','Exit');
    switch answer
        case 'Fine Scan'
            isComplete = 1;
            useFineSteps = 1;
            if showStats
                clf(f1)
                set(f1, 'Visible', 'off');
            end
            if showFigs
                clf(zArr)
                set(zArr, 'Visible', 'off');
            end
        case 'Repeat'
            if showStats
                clf(f1)
                set(f1, 'Visible', 'off');
            end
            if showFigs
                clf(zArr)
                set(zArr, 'Visible', 'off');
            end
            continue
        case 'Exit'
            isComplete = 1;
            if showFigs
                close(zArr)
            end
            if showStats
                close(f1)
            end
    end
end

% Fine scan routine
if useFineSteps
    disp('Starting fine scan...')
    isComplete = 0;
    while ~isComplete
        % Get current stage position
        startZPosFine = getStagePosition(piezo);
        % Create array for stage positions
        stagePosArrFine = linspace(startZPosFine-startPointFine,...
            startZPosFine+startPointFine,numStepsFine);

        % Move down by half of the total z distance to start at bottom
        disp(join(['Moving to -',num2str(startPointFine),' nm']))
        writeline(piezo, ['T',num2str(stagePosArrFine(1)/10)]);
        pause(stageWaitTime)
        stagePos(debugStageCounter) = getStagePosition(piezo); % nm
        debugStageCounter = debugStageCounter + 1;

        % Pre allocations for camera acquisition
        isLog = 1;
        zImagesFine = cell(1,numStepsFine);
        maxValFine = NaN(1,numStepsFine);
        % Redefine the number of triggers to send
        cam.TriggerRepeat = numStepsFine - 1;
        start(cam)
        % Step through the z positions from bottom to top, save blue channel
        for idx = 1:1:numStepsFine
            disp(join(['Imaging at ',positionStrFine(idx),' nm']))
            tic
            trigger(cam)
            while isLog
                isLog = islogging(cam);
            end
            camTimingFine(idx) = toc;
            isLog = 1;
            if idx ~= numStepsFine % Do not move if at the last iteration
                writeline(piezo, ['T',num2str(stagePosArrFine(idx+1)/10)]);
                pause(stageWaitTime)
                stagePos(debugStageCounter) = getStagePosition(piezo); % nm
                debugStageCounter = debugStageCounter + 1;
            end
            % Retrieve data from camera
            zImages3_frames = getdata(cam);
            % Already remove the noise at the edges
            zImagesFine{idx} = zImages3_frames(5:ROI(3)-5,5:ROI(4)-5,colourIdx);
            % Calculate maximum pixel brightness
            maxValFine(idx) = max(zImagesFine{idx},[],'all');
        end

        if isDevel
            debugMaxValFine(debugCounter,:) = maxValFine;
            debugExpTimeFine(debugCounter,:) = src.Shutter;
        end

        % Compensate for the fluctuations in image brightness
        if max(maxValFine) <  minBrightness
            currentExpTime = src.Shutter;      % in ms; min is 0.01 ms
            src.Shutter = currentExpTime*1.5;
            disp(join(['Maximum brightness too low, change exposure time from ',...
                num2str(currentExpTime),' ms to ',...
                num2str(currentExpTime*1.5),' ms.']))
            % Move to original start position
            disp(join(['Moving back to ',num2str(startZPosFine),' nm']))
            writeline(piezo, ['T',num2str(startZPosFine/10)]);
            pause(stageWaitTime)
            stagePos(debugStageCounter) = getStagePosition(piezo); % nm
            debugStageCounter = debugStageCounter + 1;
            continue
        elseif max(maxValFine) > maxBrightness
            currentExpTime = src.Shutter;      % in ms; min is 0.01 ms
            src.Shutter = currentExpTime*0.5;
            disp(join(['Maximum brightness too high, change exposure time from ',...
                num2str(currentExpTime),' ms to ',...
                num2str(currentExpTime*0.5),' ms.']))
            % Move to original start position
            disp(join(['Moving back to ',num2str(startZPosFine),' nm']))
            writeline(piezo, ['T',num2str(startZPosFine/10)]);
            pause(stageWaitTime)
            stagePos(debugStageCounter) = getStagePosition(piezo); % nm
            debugStageCounter = debugStageCounter + 1;
            continue
        end
        % Apply evaluation method
        thresholdValFine = max(maxValFine)*threshFactor;
        sumOfPixelsAboveThresholdFine = NaN(1,numStepsFine);
        for idxTh = 1:1:numStepsFine
            tempData = zImagesFine{idxTh};
            sumOfPixelsAboveThresholdFine(idxTh) = ...
                sum(tempData(tempData>thresholdValFine),'all');
        end
        [~,interfaceIdxFine] = max(sumOfPixelsAboveThresholdFine);
        interfacePosFineAbs = stagePosArrFine(interfaceIdxFine);
        interfacePosFine = positionNumFine(interfaceIdxFine);

        if isDevel
            debugInterfacePos(debugCounter) = interfacePosFine;
            interfaceImages{debugCounter} = zImagesFine{interfaceIdxFine};
            allImages{debugCounter} = zImagesFine;
        end

        % Navigate to interface position after formatting the command string
        disp(join(['Moving to interface at ',num2str(interfacePosFine),...
            ' nm. Setting as new 0 nm position.']))
        newPosStr = ['T',num2str(interfacePosFineAbs/10)];
        writeline(piezo, newPosStr);
        pause(stageWaitTime)
        stagePos(debugStageCounter) = getStagePosition(piezo); % nm
        debugStageCounter = debugStageCounter + 1;

        if isDevel
            debugCounter = debugCounter + 1;
        end

        if showFigs
            set(zArr, 'Visible', 'on');
            for idxPlot = 1:1:numStepsFine
                figure(zArr)
                subplot(5,ceil(numStepsFine/5),idxPlot)
                image(zImagesFine{idxPlot}(figROI(2):figROI(2)+figROI(4),...
                    figROI(1):figROI(1)+figROI(3))) % zoom in
                set(gca, 'XTickLabel', [])
                set(gca, 'YTickLabel', [])
                axis image
                title(join([num2str(positionNumFine(idxPlot)),' nm']))
            end
        end

        % Get user response on whether to continue
        % Plot data
        if showStats
            figure(f1)
            subplot(4,1,1)
            plot(positionNumFine,sumOfPixelsAboveThresholdFine)
            grid on
            xlabel('Relative Z Position (nm)')
            ylabel(join(['Sum of pixels above threshold brightness of ',...
                num2str(thresholdVal)]))
            hold on
            % Indicate the interface position
            interfaceIndicator = NaN(numStepsFine,1);
            interfaceIndicator(interfaceIdxFine) = ...
                sumOfPixelsAboveThresholdFine(interfaceIdxFine);
            plot(positionNumFine,interfaceIndicator,'ro')
            legend('',join([num2str(interfacePosFine),' nm']))
            subplot(4,1,2)
            plot(positionNumFine,maxValFine)
            grid on
            xlabel('Relative Z Position (nm)')
            ylabel('Maximum brightness values')
            subplot(4,1,3)
            plot(positionNumFine,camTimingFine)
            grid on
            zArr.Visible = 1;
            xlabel('Relative Z Position (nm)')
            ylabel('Acquisition time (s)')
            subplot(4,1,4)
            plot(stagePos)
            grid on
            xlabel('Data points')
            ylabel('Stage position (nm)')
        end
        answer = questdlg('Exit interface finder?','','Repeat','Exit','Exit');
        switch answer
            case 'Repeat'
                if showFigs
                    clf(zArr)
                    set(zArr, 'Visible', 'off');
                end
                if showStats
                    set(f1, 'Visible', 'off');
                end
                continue
            case 'Exit'
                if showFigs
                    close(zArr)
                end
                if showStats
                    close(f1)
                end
                isComplete = 1;
        end
    end
end

disp('Interface found!')

% Turn laser off, stop camera acquisition
fprintf(teensy,'LP 0.0');
disp('Laser off')
stop(cam);

% Put camera setting back to regular mode, see scrnsht of the values
cam.ROIPosition = [0 0 1280 1024];
src.FrameRate = 6;
src.Shutter = 166;      % in ms; min is 0.01 ms
src.Gain = 18;         % dB

% Take down procedure
clear teensy;
clear piezo;
delete(cam);
clear cam
objects = imaqfind; %find video input objects in memory
delete(objects)

timingTotal = toc
