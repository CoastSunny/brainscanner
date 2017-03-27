classdef EEGStream < handle
    
    properties        
        functionTimer
        % Model settings
        numChannels = 22;
        basisFunctions
        numSources
        forwardModel
        QG, verts, faces
        brainHandles
        
        % 
        isConnected = false;
        replayFileName
        replayDataFile
        showExperiment
        experimentEvents
        
        % Properties
        showTiming = 0;
        showData = 0;
        showBrain = 0;
        showChannels
        
        % Figure handles
        DataFigure; DataAxis; DataSurface;
        FreqFigure; FreqAxis; FreqPlot;
        SourceSurfFigure; SourceSurfAxis; SourceSurface;
        TimeFigure; TimeAxis; TimeSurface;
        ChannelsFigure;
        BrainFigure; BrainAxis;
        
        currentShowingChannels
        programHandle
    end
    
    
    methods % Public
        
        % Create stream
        function self = EEGStream(lib, options, programHandle)
            self.lib = lib;
            self.options = options;
            self.programHandle = programHandle;
            
            % Consider saving the properties from options that are to be
            % used later
            self.basisFunctions = options.basisFunctions;
            self.numSources = options.numSources;
            self.forwardModel = options.forwardModel;
            self.QG = options.QG;
            self.verts = options.verts;
            self.faces = options.faces;
            
            self.setup();
        end
        
        % Open stream
        function success = connect(self) 
             try 
                 self.inlet = self.createInlet(self.lib, self.options);
                 self.isConnected = true;
                 success = true;
             catch
                 self.isConnected = false;
                 success = false;
             end
        end
        
        % Close stream
        function disconnect(self)
            self.isConnected = false;
            self.inlet.close_stream();
            self.inlet.delete();
        end
        
        % Starting timer and pulling data
        function start(self)
            blockSampleRate = 1/((1/250) * self.options.blockSize); % Maybe a bit more often?
            self.pullInterval = 1/blockSampleRate;
            self.functionTimer = timer('TimerFcn',{@self.processData},'Period', self.pullInterval, 'ExecutionMode', 'fixedRate');
            
            self.showChannels = [1 2 3 4];
            start(self.functionTimer); 
        end
        
        % Stop timer and clean up
        function stop(self, varargin)
            try stop(self.functionTimer); catch; end;
            try self.disconnect(); catch; end;
            try delete(self.DataFigure); catch; end;
            try delete(self.FreqFigure); catch; end;
            try delete(self.Figure); catch; end;
            try delete(self.TimeFigure); catch; end;
            try delete(self.ChannelsFigure); catch; end;
            try delete(self.BrainFigure); catch; end;
            try delete(self.functionTimer); catch; end;
        end
        
        
        function closeFigure(self, figureHandle, varargin)
            try
                switch figureHandle
                    case self.BrainFigure
                        self.showBrain = 0;
                    case self.DataFigure
                        self.showData = 0;
                    case self.TimeFigure
                        self.showTiming = 0;
                end
                delete(figureHandle);
                if ~isempty(varargin)
                    self.programCallback();
                end
            catch e
                disp(e.message);
            end
        end
        
        function programCallback(self)
            self.programHandle.togglebutton10.Value = self.showData;
            self.programHandle.togglebutton11.Value = self.showBrain;
            self.programHandle.togglebutton14.Value = self.showTiming;
%             self.programHandle.togglebutton1.Value = self.functionTimer.Running;
        end
        
        
        % Updating function
        function processData(self, varargin)
            try
                % Loop processing time
                self.t0 = tic;
                
%                 if self.showExperiment && mod(self.functionTimer.TasksExecuted, 16) == 0  % 3 seconds
%                     event = self.experimentEvents(1);
%                     self.experimentEvents(1) = [];
%                     soundsc(y,44100,16);
%                 end
                
                if self.isConnected
                    % Read data - either from device or use cached block
                    try excessFlag = varargin{3}; catch; excessFlag = 0; end
                    try [rawData, timeStamps] = self.readDataFromDevice(excessFlag);
                    catch
                        disp('Unknown error');
                    end;
                else
                    % Read data from file
                    [rawData, timeStamps] = self.readDataFromFile();
                end
                
                % Save temp data for logging purposes
                eventData = rawData;
                logTimeStamps = timeStamps;
                
                % Make sure the correct number of samples are being processed
                try
                    [rawData, timeStamps] = self.chunkSizeCorrection(rawData, timeStamps);
                catch
                    self.logEvents(eventData, logTimeStamps, toc(self.t0)); return;
                end
                
                %% Pre-process
                processedData = self.preProcess(rawData, timeStamps);
                
                
                %% Feature extraction
                % featureData = self.featureExtraction(processedData, timeStamps);
                
                %% Various data visualization
                %             self.plotFrequencySpectrum(processedData);
                if self.showData
                    self.plotData(processedData); end
                
                if self.showTiming
                    self.plotTiming(timeStamps); end
                
                %             self.plotResults(sources);
                %             self.plotAllChannels(rawData);
                
                %% Perform source localization
                sources = self.sourceLocalization(processedData);
                if self.showBrain
                    self.plotBrain(sources); end
                
                %% Post-process
                % ?
                
                
                % Collect data and log
                self.saveData(rawData, timeStamps);
                self.logEvents(eventData, logTimeStamps, toc(self.t0));
                
                % Prepare for next sample and clean up
                self.lastSampleTimeStamp = timeStamps(end);
                
                
                % Check for full block excess data and process immediately
                if self.excessBlockSize == self.options.blockSize
                    self.processData(varargin{:}, 'excess');
                end
            catch exception
                disp(exception.message);
                disp(exception.stack(1));
                self.stop();
                self.programCallback();
            end
        end
        
        
        % Preprocess data; filtering, rereference and what not
        function processedData = preProcess(self, data, timeStamps)
            %zeroPadding = zeros(size(data));
            %data = [data zeroPadding];
            if self.options.filter
                for i=1:self.numChannels
                    data(i,:) = filtfilt(self.options.filterB, self.options.filterA, data(i,:));
                end
                %data(:,size(data,2)/2:size(data,2)) = [];
            end
            
            % Artifact removal 
            
            % Bad channel
            
            % Optionally reref the data            
            if self.options.reref
               data = bsxfun(@minus, data, mean(data)); end
            
            % Optionally zeromean or standardize data
            % Is this post-processing??
            if self.options.zeromean
                data = bsxfun(@minus, data, mean(data, 2)); end            
            if self.options.standardize
                data = bsxfun(@times, data, 1./std(data, [], 2)); end
            
            processedData = data;
        end
        
        function [featureData, freq] = featureExtraction(self, data, timeStamps)
            Fs = self.options.samplingRate;
            
%             [pxx, f] = pwelch(data');
%             freq = 0:Fs/(2*size(f,1)-1):Fs/2;
%             featureData = 10*log10(pxx');
                        
            winSize = size(data,2);
            X = fft(data',winSize)';
            X = 20*log10(abs(X)/size(X,2));
            X = X(:,1:size(X,2)/2+1);
            
            freq = 0:Fs/(2*size(X,2)-1):Fs/2;
            featureData = X;    
            
%             nfft = 2^nextpow2(size(data,2));
%             [Pxx] = abs(fft(data',nfft)).^2/size(data,2)/Fs;
%             % Create a single-sided spectrum
%             Hpsd = dspdata.psd(Pxx(1:size(Pxx,2)/2,:),'Fs',Fs);
% %             plot(Hpsd);
%             freq = Hpsd.Frequencies;
%             featureData = 20*log10(Hpsd.data');
        end

        % Localize sources 
        function sources = sourceLocalization(self, data) 
            tRecovery = tic;
            switch self.options.recoveryMethod 
                case 'MARD'
                    alphas_init = 1*ones(self.numSources, 1);
                    beta_init = 1;
                    %[alphas, beta, sources, llh] = MARD(init_alphas, 1, self.forwardModel, data);
                    [~, ~, sources, ~] = MARDv2(alphas_init, beta_init, self.forwardModel, data);
                otherwise % Do Ridge
                    lambda = 1e5;
                    PhiTPhiReg = self.forwardModel'*self.forwardModel + lambda*eye(self.numSources); 
                    sources = PhiTPhiReg\(self.forwardModel' * data);
            end
            self.recoveryTime = toc(tRecovery);
%             disp(self.recoveryTime);
        end   
    end
    
    
     properties (Hidden)
        inlet
        lib
        options
        
        pullInterval
        lastSampleTimeStamp = 0;
        recoveryTime; 
        
        previousSignal
        t0
        
        % Buffer data
        excessData=[];
        excessTime=[];
        excessBlockSize=0;
        
        % Other
        dataFileFormat
        dataHeader = 'Fp1,Fp2,F3,F4,C3,C4,P3,P4,O1,O2,F7,F8,T7,T8,P7,P8,Fz,Cz,Pz,AFz,Cpz,POz,TimeStamp';
        logFileFormat 
        logHeader = 'blockSize,timeStamp(end),bufferBlockSize,bufferTimeStamp(end),updateDuration';
    end
    
    methods (Hidden)
        %% Data acquistion and preparation
        
        % Read data input
        function [data, timeStamps] = readDataFromDevice(self, excessFlag)
            % Read data - either from device or use cached block
            if excessFlag
                data = self.excessData;
                timeStamps = self.excessTime;
                self.excessData = []; self.excessTime = []; self.excessBlockSize = 0;
                return;
            end
            
            try
                [data, timeStamps] = self.inlet.pull_chunk();
                
                % Remove two reference channels. In reality M1, M2 but
                % might be labelled as TP7 and TP8
                data(20:21,:) = [];
            catch e
                % display error message
                fprintf('EEG Stream error: %s\noccurred in:\n',e.message);
                for st = e.stack'
                    if ~isdeployed
                        try
                            fprintf('   <a href="matlab:opentoline(''%s'',%i)">%s</a>: %i\n',st.file,st.line,st.name,st.line);
                        catch
                            fprintf('   <a href="matlab:edit %s">%s</a>: %i\n',st.file,st.name,st.line);
                        end
                    else
                        fprintf('   %s: %i\n',st.file,st.line);
                    end
                end
                self.stop();
            end
        end
        
        function [rawData, timeStamps] = readDataFromFile(self)
            if isempty(self.replayDataFile)
                disp('Read file');
                tableData = readtable([self.replayFileName]);
                self.replayDataFile = tableData{:, 1:end}';
            end
            rawData = self.replayDataFile(1:end-1,1:self.options.blockSize);
            timeStamps = self.replayDataFile(end,1:self.options.blockSize);
%             self.replayDataFile(1:end-1,1:self.options.blockSize) = [];
            self.replayDataFile(:,1:self.options.blockSize) = [];
        end
        
        
        % Make sure we have the correct data chunk size 
        function [rawData, timeStamps] = chunkSizeCorrection(self, rawData, timeStamps)
            currentBlockSize = numel(timeStamps);
            
            if isempty(timeStamps) % Return if no data was ready to sample
                disp('No data');
                throw(MException('input:noData','No data'));
            end
            
            if currentBlockSize > self.options.blockSize || self.excessBlockSize + currentBlockSize > self.options.blockSize
                rawData = [self.excessData rawData];
                timeStamps = [self.excessTime timeStamps];
                
                self.excessData = rawData(:,self.options.blockSize+1:end);
                self.excessTime = timeStamps(:,self.options.blockSize+1:end);
                self.excessBlockSize = numel(self.excessTime);
                
                rawData(:,self.options.blockSize+1:end) = [];
                timeStamps(:,self.options.blockSize+1:end) = [];            
            elseif currentBlockSize < self.options.blockSize
                if ~self.excessBlockSize
                    self.excessData = rawData;
                    self.excessTime = timeStamps;
                    self.excessBlockSize = numel(self.excessTime);
                    throw(MException('input:shortBlock','Short block'));
                elseif self.excessBlockSize + currentBlockSize == self.options.blockSize
                    rawData = [self.excessData rawData];
                    timeStamps = [self.excessTime timeStamps];
                    self.excessData = []; self.excessTime = []; self.excessBlockSize = 0;
                else  % Block size mismatch - purge all in favor of speed 
                    self.excessData = []; self.excessTime = []; self.excessBlockSize = 0;
                    throw(MException('input:blockSizingMismatch','Block size mismatch'));
                end
            else
                % Removed saved data and continue as if nothing happened
                self.excessData = []; self.excessTime = []; self.excessBlockSize = 0;
            end            
        end
        

        % Save data
        function saveData(self, data, timeStamps)
            if ~self.options.saveData && ~self.isConnected
                return; end
            if ~exist('EEGData','dir')
                mkdir EEGData; end
            if ~exist(self.options.fileName, 'file')
                self.createDataFile(self.options.fileName, self.dataHeader); end
            
            fileID = fopen(self.options.fileName, 'a');
            fprintf(fileID, self.dataFileFormat, [data' timeStamps']');
            fclose(fileID);
        end
        
        function logEvents(self, data, timeStamps, updateDuration)
            if ~self.options.log && ~self.isConnected
                return; end
            if ~exist('EEGData','dir')
                mkdir EEGData; end
            if ~exist(self.options.logName, 'file')
                self.createDataFile(self.options.logName, self.logHeader); end
            
            try time = timeStamps(end); catch; time = NaN; end
            try time2 = self.excessTime(end); catch; time2 = NaN; end
            
            fileID = fopen(self.options.logName, 'a');
            fprintf(fileID, self.logFileFormat, [numel(timeStamps) time self.excessBlockSize time2 updateDuration]);
            fclose(fileID);
        end        
        
        
        function createDataFile(self, fileName, header)
            fileID = fopen(fileName, 'w');
            fprintf(fileID,'%s\n', header);
            fclose(fileID);            
        end
        

        %% Various plots
        function plotData(self, data) 
            if isempty(self.DataFigure) || ~isvalid(self.DataFigure)
                self.setupDataFigure(); end;
            
            previousData = get(self.DataSurface, 'ZData');
            signal = [previousData data];
            toRemove = max(size(signal,2), 192)-192;
            if toRemove
                signal(:,1:toRemove) = []; end               
            set(self.DataSurface, 'ZData', signal);
        end
        
        function plotFrequencySpectrum(self, data)
            if isempty(self.FreqFigure) || ~isvalid(self.FreqFigure)
                self.setupFreqFigure(); end
            
            winSize = size(data,2);
            channel = 1;
            
            X = fft(data',winSize)';
            N = size(X,2);
            
            X = 20*log10(abs(X)/N);
            X = X(:,1:N/2+1);
            
            freq = 0:self.options.samplingRate/(2*size(X,2)-1):self.options.samplingRate/2;
            
            % Plot the spectrum
            %fftData = 20*log10(abs(X)/N);
            %fftData = fftData(:,1:size(fftData,2)/2+1);
            set(self.FreqPlot, 'YData', X(channel,:), 'XData', freq);
        end
        
        function plotResults(self, results) 
            if isempty(self.SourceSurfFigure) || ~isvalid(self.SourceSurfFigure)
                self.setupSourceSurfFigure(); end;
            
            previousResults = get(self.SourceSurface, 'ZData');
            signal = [previousResults results];
            toRemove = max(size(signal,2), 192)-192;
            if toRemove
                signal(:,1:toRemove) = []; end               
            set(self.SourceSurface, 'ZData', signal);
            % titleString = sprintf('Recovery in %1.4f s', self.recoveryTime);
            % title(self.Axis,titleString);
        end
        
        
        function plotBrain(self, sources)
            if isempty(self.BrainFigure) || ~isvalid(self.BrainFigure)
                self.setupBrainFigure(); 
                brainOpts.hfig = self.BrainFigure;
                brainOpts.axes = self.BrainAxis;
                self.brainHandles = setup3DBrain(self.verts, self.faces, zeros(size(self.verts,1),1), brainOpts);
            end;
            
            fullSources = self.QG(:,self.basisFunctions) * sources;
            fullSources = sum(fullSources,2);
%             fullSources = var(fullSources,0,2);
            self.brainHandles = plot3DBrain(self.brainHandles, fullSources);
%             plot_3Dbrain(self.verts, self.faces, fullSources, opts);
        end
        
        function plotTiming(self, timeStamps)
            if self.lastSampleTimeStamp == 0;
                return; end
            
            timeDiff = (timeStamps(end) - self.lastSampleTimeStamp)*1000;
            if isempty(self.TimeFigure) || ~isvalid(self.TimeFigure)
                self.setupTimingFigure(); 
                set(self.TimeSurface, 'YData', timeDiff, 'XData', 1);
                return;
            end;
            
            previousTiming = get(self.TimeSurface, 'YData');
            timing = [previousTiming timeDiff];
            if numel(timing) > 100
                timing(1) = []; end
            
            set(self.TimeSurface, 'YData', timing, 'XData', 1:numel(timing));
%             titleString = sprintf('Pulled %i samples', numel(timeStamps));
%             title(self.TimeAxis,titleString);
        end
        
        function plotAllChannels(self, data)
            if isempty(self.ChannelsFigure) || ~isvalid(self.ChannelsFigure)
                self.setupChannelsFigure(); end;
            
            if ~min([ismember(self.showChannels, self.currentShowingChannels) ismember(self.currentShowingChannels, self.showChannels)])
                self.setupChannelsFigure(); end;
            
            signal = [self.previousSignal data];
            displaySize = 64; %256;
            toRemove = max(size(signal,2), displaySize)-displaySize;
            if toRemove
                signal(:,1:toRemove) = []; end
            
            processedData = self.preProcess(signal, []);
            [featureData, freq] = self.featureExtraction(processedData, []);
 
            subPlots = get(self.ChannelsFigure,'children');
            for i=1:numel(self.showChannels)
                channel = self.showChannels(i);
                % Raw signal
%                 set(get(subPlots(i), 'children'), 'YData', signal(channel,:), 'XData', 1:numel(signal(channel,:)));
                % Freq
                set(get(subPlots(i), 'children'), 'YData', featureData(channel,1:end), 'XData', freq(1:end));
            end
            self.previousSignal = signal;
        end        
        
        
        % Setup figures
        function setupBrainFigure(self)
            self.BrainFigure = figure('Name','Brain','Position', [100,100,560,420], 'CloseRequestFcn',{@self.closeFigure});
            self.BrainAxis = axes('Parent',self.BrainFigure,'Position',[.13 .15 .78 .75]); 
        end
        
        function setupDataFigure(self)
            self.DataFigure = figure('MenuBar','none','Name','Channels','Position', [100,100,560,420], 'CloseRequestFcn',{@self.closeFigure});
            self.DataAxis = axes('Parent',self.DataFigure,'Position',[.13 .15 .78 .75]);   % Change
            self.DataSurface = surf(zeros(self.numChannels, self.options.blockSize*2));
            ylabel(self.DataAxis,'Channel') ;
            xlabel(self.DataAxis,'Time');
        end
        
        function setupFreqFigure(self)
            self.FreqFigure = figure('MenuBar','none','Name','Freq','Position', [100,100,560,420], 'CloseRequestFcn',{@self.closeFigure});
            self.FreqAxis = axes('Parent',self.FreqFigure,'Position',[.13 .15 .78 .75]);   % Change
            self.FreqPlot = plot(zeros(1, self.options.samplingRate));
            ylabel(self.FreqAxis,'dB') ;
            xlabel(self.FreqAxis,'Hz');
        end
        
        function setupSourceSurfFigure(self)
            self.SourceSurfFigure = figure('MenuBar','none','Name','Sources','Position', [100,100,560,420], 'CloseRequestFcn',{@self.closeFigure});
            self.SourceSurfAxis = axes('Parent',self.SourceSurfFigure,'Position',[.13 .15 .78 .75]);   % Change
            self.SourceSurface = surf(zeros(self.numSources, self.options.blockSize*2));
            ylabel(self.Axis,'Source index') ;
            xlabel(self.Axis,'Time');
        end
        
        function setupTimingFigure(self)
            self.TimeFigure = figure('MenuBar','none','Name','Timing','Position', [800,100,560,420], 'CloseRequestFcn',{@self.closeFigure});
            self.TimeAxis = axes('Parent',self.TimeFigure,'Position',[.13 .15 .78 .75]);   % Change
            self.TimeSurface = plot(0,0);
            ylabel(self.TimeAxis,'Time');
            xlabel(self.TimeAxis,'Sample');  
        end
                
        function setupChannelsFigure(self)
            if isempty(self.ChannelsFigure)
                self.ChannelsFigure = figure('MenuBar','none','Name','Sources','Position', [800,600,560,420], 'CloseRequestFcn',{@self.closeFigure}); 
            end
            figure(self.ChannelsFigure);
            
            %self.ChannelAxis = axes('Parent',self.ChannelsFigure,'Position',[.13 .15 .78 .75]);   % Change
            for i=1:numel(self.showChannels) %self.numChannels
                subplot(ceil(numel(self.showChannels)/2),2,i), plot(0,0);
                title(sprintf('Channel %d', self.showChannels(i)));
                %ylabel(self.ChannelAxis,'Time');
                %xlabel(self.ChannelAxis,'Sample');  
            end
            self.currentShowingChannels = self.showChannels;
        end

        
        
        %% Utility functions
        function setup(self)
            self.options.fileName = ['EEGData/raw_' datestr(datetime, 'dd-mm-yyyy HH-MM-SS') '.csv'];
            self.options.logName = ['EEGData/log' datestr(datetime, 'dd-mm-yyyy HH-MM-SS') '.csv'];
            self.dataFileFormat = '';
            for i=1:22
                self.dataFileFormat = [self.dataFileFormat '%1.4f,'];
            end
            self.dataFileFormat = [self.dataFileFormat '%1.6f\n'];
            
            self.logFileFormat = '%d,%1.6f,%d,%1.6f,%1.6f\n';
        end
        
        
        % create an inlet to read from the stream with the given name
        function inlet = createInlet(self, lib, opts)
            % look for the desired device
            result = {};
            disp(['Looking for a stream with name=' opts.eegStreamName ' ...']);
            tryCounter = 0;
            while tryCounter < 5 && isempty(result)
                result = lsl_resolve_byprop(lib,'name',opts.eegStreamName,1,2); 
                tryCounter = tryCounter+1;
            end
            if isempty(result)
                disp('Could not find inlet...');
                return;
            end
            % create a new inlet
            disp('Opening an inlet...');
            inlet = lsl_inlet(result{1}, opts.bufferrange);
        end
        
        
        % create a new stream buffer to hold our data
        function stream = createStreambuffer(self, opts, info)
            stream.srate = info.nominal_srate();
            stream.chanlocs = struct('labels', self.deriveChannelLabels(info));
            
            % I think this can be removed ?!? 
%             stream.buffer = zeros(length(stream.chanlocs), max(max(opts.bufferrange, opts.timerange)*stream.srate,100));
%             [stream.nsamples,stream.state] = deal(0,[]);
        end
                
        % derive a list of channel labels for the given stream info
        function channels = deriveChannelLabels(self, info)
            channels = {};
            ch = info.desc().child('channels').child('channel');
            while ~ch.empty()
                name = ch.child_value_n('label');
                if name
                    channels{end+1} = name; end %#ok<AGROW>
                ch = ch.next_sibling_n('channel');
            end
            if length(channels) ~= info.channel_count()
                disp('The number of channels in the steam does not match the number of labeled channel records. Using numbered labels.');
                channels = cellfun(@(k)['Ch' num2str(k)],num2cell(1:info.channel_count(),1),'UniformOutput',false);
            end
        end
        
    end %methods
    
end