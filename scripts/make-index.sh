#!/usr/bin/env bash
#
# Set job time
#SBATCH --time=04:00:00
#
# Set memory requested and max memory
#SBATCH --mem=4gb
#
# Request some processors
#SBATCH --cpus-per-task=1
#SBATCH --ntasks=1

if [ $# -lt 4 ]; then
	echo 
	echo "Create index for bowtie2"
	echo
	echo
	echo "All arguments for this script are the arguments for bowtie2-index"
	echo
	echo "Usage:"
	echo
	echo "	bash make-index.sh <input_reference.fasta> <index_prefix> <jobfile> <bt2mod>" 
	echo
	echo "	<input_reference.fasta> - fasta or gzipped fasta file"
	echo "	<index_prefix>          - prefix for the output files"
	echo "	<jobfile>               - output for dummy file"
	echo "	<bt2mod>                - bowtie2 module (e.g. bowtie/2.2)"
	echo
	exit
fi

INPUT_REF=$1
INDEX_PREFIX=$2
JOBFILE=$3
BOWTIE=$4
CMD="bowtie2-build --seed 99"


if [[ $INPUT_REF == *gz ]]; then
	WRITE_TMP="zcat $INPUT_REF > \$TMPDIR/tmp.fa"
	CMD="$WRITE_TMP; $CMD \$TMPDIR/tmp.fa $INDEX_PREFIX"
else 
	CMD="$CMD $INPUT_REF $INDEX_PREFIX"
fi

module load $BOWTIE
# Run the command through time with memory and such reporting.
# warning: there is an old bug in GNU time that overreports memory usage
# by 4x; this is compensated for in the SGE_Plotdir script.
TIME='/usr/bin/env time -f " \\tFull Command:                      %C \\n\\tMemory (kb):                       %M \\n\\t# SWAP  (freq):                    %W \\n\\t# Waits (freq):                    %w \\n\\tCPU (percent):                     %P \\n\\tTime (seconds):                    %e \\n\\tTime (hh:mm:ss.ms):                %E \\n\\tSystem CPU Time (seconds):         %S \\n\\tUser   CPU Time (seconds):         %U " '

# Write details to stdout
echo "  Job: $SLURM_JOB_ID"
echo
echo "  Started on:           " `/bin/hostname -s`
echo "  Started at:           " `/bin/date`
echo $CMD

# Writing to a jobfile before the command is executed allows for a hack to make
# a target for the Makefile that is older than the multiple files for output.
# printf "$SLURM_JOB_ID\n" > $JOBFILE

eval $TIME$CMD # Running the command.

echo "  Finished at:           " `date`
echo
# End of file
