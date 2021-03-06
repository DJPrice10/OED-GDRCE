
% clear

myCluster = parcluster('local');
myCluster.NumWorkers = 4;
saveProfile(myCluster);
                  
rng(1)

totaltime = tic;

number_of_data=100000;

% % % % % % % % % % % % % % % % % % % % % % % % %
% % % Define prior distribution parameters% % % %
% % % % % % % % % % % % % % % % % % % % % % % % %

% Inputs for prior distributions for each parameter
ID50_prior_params = [14.5, 0.35];
SHH_prior_params = [12, 0.025];
rho = -0.85;

beta_prior_params = [1.0, 3.0];

% End points of parameter space to consider
upper_limits=[15.0, 0.7950];
lower_limits=[1.00, 0.0005];

% % % IMPORTANT: Upper limit on slope-at-half-height is without violating 
% the assumption of indep. action is given by (1/2)*log(10)*log(2) ? 0.798015.
% Proposed limit of 0.79 to allow fzero to solve for alpha without issue,
% while still approaching this biological limit.

% % % % % % % % % % % % % % % % % % % % % %
% % % Define experimental parameters% % % %
% % % % % % % % % % % % % % % % % % % % % %

% Design specific parameters
nchickens=40;
maxngroups = 5;

% Shape and rate parameters for the Erlang distributed latent period. 
% nclasses must be integer.
exposure_rate=2;
nclasses=2;

% Step size for design space; dose (log10 CFU) and time
dose_stepsize = 0.5;
time_stepsize= 0.05;

% Grid spacing on design space
dose_limits = [dose_stepsize, 10];
time_limits = [time_stepsize, 6];

% ABC tolerance
tol=.25;

% % % % % % % % % % % % % % % % % % % % % % % % % % % % % %
% % %  Define prior distribution across grid points % % % %
% % % % % % % % % % % % % % % % % % % % % % % % % % % % % %

n=100;
MAX_XY=upper_limits;
MIN_XY=lower_limits;

scaling=MAX_XY-MIN_XY;
% Get same values used to evaluate posterior
[X,Y]=meshgrid(MIN_XY(1):scaling(1)/(n-1):MAX_XY(1),MIN_XY(2):scaling(2)/(n-1):MAX_XY(2));

Xctrs = X(1,:);
Yctrs = Y(:,1);

% Evaluate prior at those values



X1 = ones(number_of_data, 2);

while (any(X1(:,2)>upper_limits(2)))
    Z1 = mvnrnd([0 0], [1 rho; rho 1], number_of_data);
    U1 = normcdf(Z1);
    X1 = [gaminv(U1(:,1),ID50_prior_params(1), ID50_prior_params(2)) gaminv(U1(:,2), SHH_prior_params(1), SHH_prior_params(2))];
end


ID50_idx = interp1(Xctrs,1:numel(Xctrs),X1(:,1),'nearest');
SHH_idx = interp1(Yctrs,1:numel(Yctrs),X1(:,2),'nearest');

ID50_params = Xctrs(ID50_idx)'; 
SHH_params = Yctrs(SHH_idx);

% Xprior = normpdf(X, ID50_prior_params(1), ID50_prior_params(2));
% Yprior = normpdf(Y,SHH_prior_params(1),SHH_prior_params(2));


% Sample param indices according to weights (X/Y/Zprior)
% ID50_idx = randsample(1:length(Xctrs), number_of_data, true, Xprior(1,:));
% SHH_idx = randsample(1:length(Yctrs), number_of_data, true, Yprior(:,1));

% Get param values corresponding to indices
% ID50_params = Xctrs(ID50_idx)';
% SHH_params = Yctrs(SHH_idx);


prior_values = [ID50_params, SHH_params];

% Use alpha/delta values to simulate P_inf
% alpha_params = arrayfun(@(x) eval(solve(x==log(10)/2*a*(1-0.5^(1/a)),a)), SHH_params);
alpha_params = arrayfun(@(x) fzero(@(a) x-log(10)/2*a*(1-0.5^(1/a)),[0.001 150]), SHH_params);
delta_params = ID50_params./(2.^(1./alpha_params)-1);

% Evaluate prior grid using indices (accumarray counts number of each
% index on an n*n*n grid)
prior_grid = accumarray([ID50_idx, SHH_idx], 1, [n n]);
prior_grid = bsxfun(@rdivide, prior_grid, sum(sum(sum(prior_grid))));


% Random beta values, but not trying to estimate them
zvals = beta_prior_params(1):(beta_prior_params(2)-beta_prior_params(1))/(n-1):beta_prior_params(2);

Zprior = 1/(max(zvals)-min(zvals)) * ones(n,1);
beta_idx = randsample(1:length(zvals), number_of_data, true, Zprior);
beta_params = zvals(beta_idx);



clear('X','Y', 'Xprior','Yprior','Zprior', 'Xctrs','Yctrs', 'zvals', 'X1','Z1','U1')
% % % % % % % % % % % % % % % % % % % % % % % % % % % % % %
% % % % % % Set INSH convergence parameters % % % % % %
% % % % % % % % % % % % % % % % % % % % % % % % % % % % % %

% Number of iterations
W=60;

% Iterations at which to increase exploitation
stepdown = [30, 15, 15];

% if (sum(stepdown)~=W)
%     fprintf('Error: Make sure sum stepdown equals W. \n')
%     return;
% end

% No. of new designs to sample, and to keep, at each iteration
m=[3*ones(stepdown(1),1); 6*ones(stepdown(2),1); 15*ones(stepdown(3),1)];
ntokeep = [150*ones(stepdown(1),1); 75*ones(stepdown(2),1); 30*ones(stepdown(3),1)];

% Reduce standard deviation to hone in on designs around optimal region
time_sample_sd= [0.1*ones(stepdown(1),1); 0.075*ones(stepdown(2),1); 0.05*ones(stepdown(3),1)];
dose_sample_sd= [1.0*ones(stepdown(1),1); 0.75*ones(stepdown(2),1); 0.5*ones(stepdown(3),1)];

% If want fixed standard deviation throughout, use =sigma*ones(W,1);

%%
% Initial number of designs to be considered at each of 2,3,4,5 group
% sizes. Must be maxngroups-1 in length.
ninitialdesignspergroupsize = [50, 100, 250, 500];


% Randomly generate the initial designs.
current_wave_designs = [];

for i=2:maxngroups
    current_wave_designs = [current_wave_designs; zeros(ninitialdesignspergroupsize(i-1), maxngroups-i) repmat(floor(nchickens/i), ninitialdesignspergroupsize(i-1), i)  zeros(ninitialdesignspergroupsize(i-1), maxngroups-i)  round(unifrnd(dose_limits(1)*ones(ninitialdesignspergroupsize(i-1),i), dose_limits(2))/dose_stepsize)*dose_stepsize   zeros(ninitialdesignspergroupsize(i-1), maxngroups-i)   round(unifrnd(time_limits(1)*ones(ninitialdesignspergroupsize(i-1),i), time_limits(2))/time_stepsize)*time_stepsize   ];
end




% Order the designs according to the dose. Re-order the obs. times 
% according to the dose ordering. 

for i=1:size(current_wave_designs,1)
    [B, I] = sort(current_wave_designs(i, (maxngroups+1):(2*maxngroups)));
    current_wave_designs(i, (maxngroups+1):(2*maxngroups)) = B;
    
    ts = current_wave_designs(i, (2*maxngroups+1):(3*maxngroups));
    current_wave_designs(i, (2*maxngroups+1):(3*maxngroups)) = ts(I);
    
end



keep_all = [];


for w=1:W 
   fprintf('Wave: %u\n', w)
   
    % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % %
    % % % % Simulate data at each of the current unique designs % % %
    % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % %
    
    % Manipulate the data set so that I can simulate easily. Split out each
    % group independently, and simulate the groups. Then, stick them back
    % together when evaluating the utility for each design
    
    groupsizes = current_wave_designs(:,1:maxngroups);
    doses = current_wave_designs(:,(maxngroups+1):(2*maxngroups));
    times = current_wave_designs(:,(2*maxngroups+1):(3*maxngroups));
    
    allgroupdesigns = [groupsizes(:), doses(:), times(:)];
    % Retain only those that aren't all zero
    allgroupdesigns( ~any(allgroupdesigns,2), : ) = [];
    
    % Get only unique designs
    allgroupdesigns = unique(allgroupdesigns, 'rows');
    
%     sprintf('No. unique group designs: %u', size(allgroupdesigns,1))
    
    % Get the unique number of chickens and doses to create initial number
    % of exposed chickens according to these values
    unique_n_d = unique(allgroupdesigns(:,1:2), 'rows');
    
    % Dose only comes into the equation here, the initial number of "exposed"
    prob_inf = (1-bsxfun(@power, 1+bsxfun(@ldivide, delta_params, 10.^unique_n_d(:,2)'), -alpha_params));
    initially_exposed_data = binornd(repmat(unique_n_d(:,1)',number_of_data, 1), prob_inf);
    
    clear('prob_inf')
    
    data = zeros(number_of_data, size(allgroupdesigns,1));
    % testdat = data;
    
    % Forward simulate each of the groups according to SEKI dynamics with
    % transmission_rate in beta_params(j). 
    for i=1:size(unique_n_d,1)
        groupsize = unique_n_d(i,1);
        
        ind = ismember(allgroupdesigns(:,1:2), unique_n_d(i,:), 'rows')';
        possibletimes = allgroupdesigns(ind, 3);
        
        tmpdat = zeros(number_of_data, sum(ind));
        parfor j=1:number_of_data
                tmpdat(j,:) = getdataSEKI(beta_params(j), exposure_rate, groupsize, initially_exposed_data(j,i), possibletimes, nclasses);
        end
        
        data(:,ind) = tmpdat;   
    end
    
    clear('initially_exposed_data', 'tmpdat')
    
    % Data now has a column corresponding to each unique group in the original
    % proposed designs. Need to now stitch these back together in some way when
    % evaluating the posterior distribution for each
    
    % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % %
    % % % % Evaluate utility at each design using ABCdE approach  % %
    % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % %

    kld = zeros(size(current_wave_designs,1),1);
   
    parfor i=1:size(current_wave_designs,1)
        tmpdesign = [current_wave_designs(i,1:maxngroups)' current_wave_designs(i,(maxngroups+1):(2*maxngroups))' current_wave_designs(i,(2*maxngroups+1):(3*maxngroups))'];
        tmpdesign(~any(tmpdesign,2),:)=[];
        
        % locb gives the rows of allgroupdesigns that together make current
        % design. These also correspond to the columns that will then be used to
        % form the observed data used for evaluating the posterior distribution
        [~, locb] = ismember(tmpdesign, allgroupdesigns, 'rows');
        
        tmp_data=data(:,locb);
        
        % Grab unique data sets, and number of times each occurs
        [uni_data, num, ~] = howmanyunique(tmp_data);
        
        tmp_kld=zeros(size(uni_data,1),1);
        
        % Get std dev's for ABC discrepancy
        std_tmp = std(tmp_data);
        
        for k=1:size(uni_data,1)
            keep = ABCDE_chunk(tmp_data, uni_data(k,:), std_tmp)<(tol*size(tmpdesign,1));
            
            % Evaluate ABC posterior
            xr = ID50_idx(keep);
            yr = SHH_idx(keep);
                      
            lendens = length(xr);
            % Count number of each index
            [URP, numURP] = howmanyunique([xr yr]);
            % Give index of prior values
            pos = sub2ind([n,n],URP(:,1),URP(:,2));
            % Normalise
            denspos = numURP/lendens;
            % Evaluate KLD
            tmp_kld(k) = (log(denspos) - log(prior_grid(pos)))'*denspos;
        end
        % Evaluate utility for design i, as the average utility contribution
        % from each unique data set
        kld(i) = dot(tmp_kld, num/sum(num));
        
        
    end
    
    clear('data')
    % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % %
    % % Store all sampled design points and corresponding utility % %
    % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % %
    
    keep_all = [keep_all; [current_wave_designs, kld, w*ones(length(kld),1)]];
    
    % Acceptance Criteria
    sortklds = sort(kld,'descend');
    accept_cutoff = sortklds(ntokeep(w));
    update_wave = current_wave_designs(kld >= accept_cutoff, :);
    
    % Include the optimal design thus far in the update wave so that we
    % keep exploring the space around the optimal, rather than hitting it
    % then moving away from it
    
    if(keep_all(keep_all(:,3*maxngroups+1)==max(keep_all(:,3*maxngroups+1)),end)~=w)
        update_wave = [update_wave; keep_all((keep_all(:,3*maxngroups+1)==max(keep_all(:,3*maxngroups+1))),1:3*maxngroups)];
    end

    
    % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % %
    % % % % % Sample new designs around accepted designs % % % % % %
    % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % %

    nonzero_indicator = update_wave>0;
    ngroupsperdesign = sum(nonzero_indicator,2)/3; % as {(G,A,T)}/3=No. groups
    
    current_wave_designs = [];
    for k=1:size(update_wave,1)
        current_wave_designs = [current_wave_designs; zeros(m(w), maxngroups-ngroupsperdesign(k)),  repmat(floor(nchickens/ngroupsperdesign(k)), m(w), ngroupsperdesign(k)), zeros(m(w), maxngroups-ngroupsperdesign(k)),  discrete_trunc_sample(update_wave(k,(2*maxngroups-ngroupsperdesign(k)+1):(2*maxngroups)), dose_limits, dose_sample_sd(w)*eye(ngroupsperdesign(k)) , dose_stepsize, m(w)),...
            zeros(m(w), maxngroups-ngroupsperdesign(k)),  discrete_trunc_sample(update_wave(k,(3*maxngroups-ngroupsperdesign(k)+1):(3*maxngroups)), time_limits, time_sample_sd(w)*eye(ngroupsperdesign(k)) , time_stepsize, m(w)) ];
    end
    
    % Add OED back in to be re-evaluated at next iteration
    current_wave_designs = [current_wave_designs; keep_all((keep_all(:,3*maxngroups+1)==max(keep_all(:,3*maxngroups+1))),1:3*maxngroups)];
    

    for i=1:size(current_wave_designs,1)
        [B, I] = sort(current_wave_designs(i, (maxngroups+1):(2*maxngroups)));
        current_wave_designs(i, (maxngroups+1):(2*maxngroups)) = B;
        
        ts = current_wave_designs(i, (2*maxngroups+1):(3*maxngroups));
        current_wave_designs(i, (2*maxngroups+1):(3*maxngroups)) = ts(I);
        
    end
end

runtime = toc(totaltime);

% Create a final column containing the number of groups
ng = sum(keep_all(:,1:maxngroups)>0, 2);
keep_all = [keep_all, ng];
%


save('Output_uninf_IS_EKLD_id50_shh.mat')


