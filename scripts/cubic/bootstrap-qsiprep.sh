## NOTE ##
# This workflow is derived from the Datalad Handbook

## Ensure the environment is ready to bootstrap the analysis workspace
# Check that we have conda installed
#conda activate
#if [ $? -gt 0 ]; then
#    echo "Error initializing conda. Exiting"
#    exit $?
#fi

DATALAD_VERSION=$(datalad --version)

if [ $? -gt 0 ]; then
    echo "No datalad available in your conda environment."
    echo "Try pip install datalad"
    # exit 1
fi

echo USING DATALAD VERSION ${DATALAD_VERSION}

set -e -u


## Set up the directory that will contain the necessary directories
PROJECTROOT=${PWD}/qsiprep
if [[ -d ${PROJECTROOT} ]]
then
    echo ${PROJECTROOT} already exists
    # exit 1
fi

if [[ ! -w $(dirname ${PROJECTROOT}) ]]
then
    echo Unable to write to ${PROJECTROOT}\'s parent. Change permissions and retry
    # exit 1
fi


## Check the BIDS input
BIDSINPUT=$1
if [[ -z ${BIDSINPUT} ]]
then
    echo "Required argument is an identifier of the BIDS source"
    # exit 1
fi

# Is it a directory on the filesystem?
BIDS_INPUT_METHOD=clone
if [[ -d "${BIDSINPUT}" ]]
then
    # Check if it's datalad
    BIDS_DATALAD_ID=$(datalad -f '{infos[dataset][id]}' wtf -S \
                      dataset -d ${BIDSINPUT} 2> /dev/null || true)
    [ "${BIDS_DATALAD_ID}" = 'N/A' ] && BIDS_INPUT_METHOD=copy
fi


## Start making things
mkdir -p ${PROJECTROOT}
cd ${PROJECTROOT}

# Jobs are set up to not require a shared filesystem (except for the lockfile)
# ------------------------------------------------------------------------------
# RIA-URL to a different RIA store from which the dataset will be cloned from.
# Both RIA stores will be created
input_store="ria+file://${PROJECTROOT}/input_ria"
output_store="ria+file://${PROJECTROOT}/output_ria"

# Create a source dataset with all analysis components as an analysis access
# point.
datalad create -c yoda analysis
cd analysis

# create dedicated input and output locations. Results will be pushed into the
# output sibling and the analysis will start with a clone from the input sibling.
datalad create-sibling-ria -s output "${output_store}"
pushremote=$(git remote get-url --push output)
datalad create-sibling-ria -s input --storage-sibling off "${input_store}"

# register the input dataset
if [[ "${BIDS_INPUT_METHOD}" == "clone" ]]
then
    echo "Cloning input dataset into analysis dataset"
    datalad clone -d . ${BIDSINPUT} inputs/data
    # amend the previous commit with a nicer commit message
    git commit --amend -m 'Register input data dataset as a subdataset'
else
    echo "WARNING: copying input data into repository"
    mkdir -p inputs/data
    cp -r ${BIDSINPUT}/* inputs/data
    datalad save -r -m "added input data"
fi

SUBJECTS=$(find inputs/data -type d -name 'sub-*' | cut -d '/' -f 3 | sort)
if [ -z "${SUBJECTS}" ]
then
    echo "No subjects found in input data"
    # exit 1
fi


## Add the containers as a subdataset
cd ${PROJECTROOT}

# Clone the containers dataset. If specified on the command, use that path
CONTAINERDS=$2
if [[ ! -z "${CONTAINERDS}" ]]; then
    datalad clone ${CONTAINERDS} pennlinc-containers
else
    echo ERROR: requires a container dataset
    exit 1
fi

cd ${PROJECTROOT}/analysis
datalad install -d . --source ${PROJECTROOT}/pennlinc-containers

## the actual compute job specification
cat > code/participant_job.sh << "EOT"
#!/bin/bash
#$ -S /bin/bash
#$ -l h_vmem=32G
#$ -l s_vmem=30.5G
#$ -l tmpfree=300G
#$ -pe threaded 6
# Set up the correct conda environment
source ${CONDA_PREFIX}/bin/activate base
echo I\'m in $PWD using `which python`

# fail whenever something is fishy, use -x to get verbose logfiles
set -e -u -x

# Set up the remotes and get the subject id from the call
dssource="$1"
pushgitremote="$2"
subid="$3"

# change into the cluster-assigned temp directory. Not done by default in SGE
cd ${CBICA_TMPDIR}
# OR Run it on a shared network drive
# cd /cbica/comp_space/$(basename $HOME)

# Used for the branch names and the temp dir
BRANCH="job-${JOB_ID}-${subid}"
mkdir ${BRANCH}
cd ${BRANCH}

# get the analysis dataset, which includes the inputs as well
# importantly, we do not clone from the lcoation that we want to push the
# results to, in order to avoid too many jobs blocking access to
# the same location and creating a throughput bottleneck
datalad clone "${dssource}" ds

# all following actions are performed in the context of the superdataset
cd ds

# in order to avoid accumulation temporary git-annex availability information
# and to avoid a syncronization bottleneck by having to consolidate the
# git-annex branch across jobs, we will only push the main tracking branch
# back to the output store (plus the actual file content). Final availability
# information can be establish via an eventual `git-annex fsck -f joc-storage`.
# this remote is never fetched, it accumulates a larger number of branches
# and we want to avoid progressive slowdown. Instead we only ever push
# a unique branch per each job (subject AND process specific name)
git remote add outputstore "$pushgitremote"

# all results of this job will be put into a dedicated branch
git checkout -b "${BRANCH}"

# we pull down the input subject manually in order to discover relevant
# files. We do this outside the recorded call, because on a potential
# re-run we want to be able to do fine-grained recomputing of individual
# outputs. The recorded calls will have specific paths that will enable
# recomputation outside the scope of the original setup
datalad get -n "inputs/data/${subid}"

# Reomve all subjects we're not working on
(cd inputs/data && rm -rf `find . -type d -name 'sub*' | grep -v $subid`)

# ------------------------------------------------------------------------------
# Do the run!

datalad run \
    -i code/qsiprep_zip.sh \
    -i inputs/data/${subid} \
    -i inputs/data/*json \
    -i pennlinc-containers/.datalad/environments/qsiprep-0-14-2/image \
    --explicit \
    -o ${subid}_qsiprep-0.13.1.zip \
    -m "qsiprep:0.13.1 ${subid}" \
    "bash ./code/qsiprep_zip.sh ${subid}"

# file content first -- does not need a lock, no interaction with Git
datalad push --to output-storage
# and the output branch
flock $DSLOCKFILE git push outputstore

echo SUCCESS
# job handler should clean up workspace
EOT

chmod +x code/participant_job.sh

cat > code/qsiprep_zip.sh << "EOT"
#!/bin/bash
set -e -u -x

subid="$1"

mkdir -p ${PWD}/.git/tmp/wdir
singularity run --cleanenv -B ${PWD} \
    pennlinc-containers/.datalad/environments/qsiprep-0-14-2/image \
    inputs/data \
    prep \
    participant \
    -w ${PWD}/.git/wkdir \
    --n_cpus $NSLOTS \
    --stop-on-first-crash \
    --fs-license-file code/license.txt \
    --skip-bids-validation \
    --participant-label "$subid" \
    --unringing-method mrdegibbs \
    --output-resolution 1.8

cd prep
7z a ../${subid}_qsiprep-0.13.1.zip qsiprep
rm -rf prep .git/tmp/wkdir

EOT

chmod +x code/qsiprep_zip.sh
cp ${FREESURFER_HOME}/license.txt code/license.txt

mkdir logs
echo .SGE_datalad_lock >> .gitignore
echo logs >> .gitignore

datalad save -m "Participant compute job implementation"

cat > code/merge_outputs.sh << "EOT"
#!/bin/bash
set -e -u -x
EOT

# Add a script for merging outputs
MERGE_POSTSCRIPT=https://raw.githubusercontent.com/PennLINC/TheWay/main/scripts/cubic/merge_outputs_postscript.sh
echo "outputsource=${output_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)" \
    >> code/merge_outputs.sh
echo "cd ${PROJECTROOT}" >> code/merge_outputs.sh
wget -qO- ${MERGE_POSTSCRIPT} >> code/merge_outputs.sh

################################################################################
# SGE SETUP START - remove or adjust to your needs
################################################################################
env_flags="-v DSLOCKFILE=${PWD}/.SGE_datalad_lock"
echo '#!/bin/bash' > code/qsub_calls.sh
dssource="${input_store}#$(datalad -f '{infos[dataset][id]}' wtf -S dataset)"
pushgitremote=$(git remote get-url --push output)
eo_args="-e ${PWD}/logs -o ${PWD}/logs"
for subject in ${SUBJECTS}; do
    echo "qsub -cwd ${env_flags} -N qp${subject} ${eo_args} \
    ${PWD}/code/participant_job.sh \
    ${dssource} ${pushgitremote} ${subject}" >> code/qsub_calls.sh
done
datalad save -m "SGE submission setup" code/ .gitignore

################################################################################
# SGE SETUP END
################################################################################

# cleanup - we have generated the job definitions, we do not need to keep a
# massive input dataset around. Having it around wastes resources and makes many
# git operations needlessly slow
if [ "${BIDS_INPUT_METHOD}" = "clone" ]
then
    datalad uninstall -r --nocheck inputs/data
fi


# make sure the fully configured output dataset is available from the designated
# store for initial cloning and pushing the results.
datalad push --to input
datalad push --to output

# if we get here, we are happy
echo SUCCESS
