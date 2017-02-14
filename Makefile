# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Makefile for analyzing mitochondrial genomes
#
# Author: Zhian N. Kamvar
# Licesne: MIT
#
# This makefile contains rules and recipes for mapping, filtering, and
# analyzing mitochondrial genomes of *Sclerotinia sclerotiorum* treated with
# four different fungicides to assess the impact of fungicide stress on genomic
# architecture.
#
# Since this makefile runs on a SLURM cluster, this is tailored specifically for
# the HCC cluster in UNL. For this to work, the script SLURM_Array must be in 
# your path. You can download it here: https://github.com/zkamvar/SLURM_Array
#
# The general pattern of this makefile is that each target takes two steps:
#
# 1. Run a bash script to collect the dependencies into separate lines of a
#    text file. Each line will be an identical command to run in parallel
#    across the cluster.
# 2. The text file is submitted to the cluster with SLURM_Array
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.PHONY: all index help map clean

all: index map gvcf


EMAIL    := ***REMOVED***
ROOT_DIR := $(shell echo $$WORK/Sclerotinia_mitochondria) 
ROOT_DIR := $(strip $(ROOT_DIR))
TMP      := \$$TMPDIR
IDX_DIR  := bt2-index
BOWTIE   := bowtie/2.2
SAMTOOLS := samtools/1.3
PICARD   := picard/1.1
GATK     := gatk/3.4
gatk     := \$$GATK
PIC      := \$$PICARD
SAM_DIR  := SAMS
BAM_DIR  := BAMS
GVCF_DIR := GVCF
REF_DIR  := REF
RUNFILES := runfiles
FASTA    := mitochondria_genome/sclerotinia_sclerotiorum_mitochondria_2_supercontigs.fasta.gz
REF_IDX  := $(patsubst mitochondria_genome/%.fasta.gz,$(REF_DIR)/%.fasta, $(FASTA))
PREFIX   := Ssc_mito # prefix for the bowtie2 index
READS    := $(shell ls -d reads/*_1.fq.gz | sed 's/_1.fq.gz//g')
RFILES   := $(addsuffix _1.fq.gz, $(READS))
IDX      := $(addprefix $(strip $(IDX_DIR)/$(PREFIX)), .1.bz2 .2.bz2 .3.bz2 .4.bz2 .rev.1.bz2 .rev.2.bz2)
SAM      := $(patsubst reads/%.sam, $(SAM_DIR)/%.sam, $(addsuffix .sam, $(READS)))
SAM_VAL  := $(patsubst %.sam, %_stats.txt.gz, $(SAM))
BAM      := $(patsubst $(SAM_DIR)/%.sam, $(BAM_DIR)/%_nsort, $(SAM))
FIXED    := $(patsubst %_nsort, %_fixed.bam, $(BAM))
DUPMRK   := $(patsubst %_nsort, %_dupmrk.bam, $(BAM))
GVCF     := $(patsubst reads/%,$(GVCF_DIR)/%.g.vcf.gz, $(READS))
DUP_VAL  := $(patsubst %_nsort, %_dupmrk_stats.txt.gz, $(BAM))
BAM_VAL  := $(patsubst %_fixed.bam, %_fixed_stats.txt.gz, $(FIXED))

$(RUNFILES) $(IDX_DIR) $(SAM_DIR) $(BAM_DIR) $(REF_DIR) $(GVCF_DIR):
	-mkdir $@
index : $(FASTA) $(IDX) 
map : $(IDX) $(SAM) $(SAM_VAL) $(BAM) $(FIXED) $(BAM_VAL) $(DUPMRK) $(DUP_VAL)
gvcf : $(REF_IDX) $(GVCF)

runs/BOWTIE2-BUILD/BOWTIE2-BUILD.sh : scripts/make-index.sh $(FASTA) | $(IDX_DIR) $(RUNFILES)
	$^ $(addprefix $(IDX_DIR)/, $(PREFIX)) 
	SLURM_Array -c $(RUNFILES)/make-index.txt \
		-r runs/BOWTIE2-BUILD \
		-l $(BOWTIE) \
		-w $(ROOT_DIR)

$(IDX) : scripts/make-index.sh $(FASTA) runs/BOWTIE2-BUILD/BOWTIE2-BUILD.sh

runs/MAP-READS/MAP-READS.sh: scripts/make-alignment.sh $(RFILES) | $(SAM_DIR) 
	$< $(addprefix $(IDX_DIR)/, $(PREFIX)) $(SAM_DIR) $(READS)
	SLURM_Array -c $(RUNFILES)/make-alignment.txt \
		--mail $(EMAIL) \
		-r runs/MAP-READS \
		-l $(BOWTIE) \
		--hold \
		-w $(ROOT_DIR)

$(SAM) : scripts/make-alignment.sh $(RFILES) runs/MAP-READS/MAP-READS.sh


runs/VALIDATE-SAM/VALIDATE-SAM.sh: $(SAM) | $(SAM_DIR) 
	echo $^ | \
	sed -r 's/'\
	'($(SAM_DIR)[^ ]+?).sam *'\
	'/'\
	'samtools stats \1.sam | gzip -c > \1_stats.txt.gz\n'\
	'/g' > $(RUNFILES)/validate-sam.txt # end
	SLURM_Array -c $(RUNFILES)/validate-sam.txt \
		--mail $(EMAIL) \
		-r runs/VALIDATE-SAM \
		-l $(SAMTOOLS) \
		--hold \
		-w $(ROOT_DIR)

$(SAM_VAL): $(SAM) runs/VALIDATE-SAM/VALIDATE-SAM.sh

# SAMTOOLS SPECIFICATIONS
#
# http://www.htslib.org/doc/
# view
# # -b       output BAM
# # -S       ignored (input format is auto-detected)
# # -u       uncompressed BAM output (implies -b)
#
# sort
# # -n         Sort by read name
# # -o FILE    output file name [stdout]
# # -O FORMAT  Write output as FORMAT ('sam'/'bam'/'cram')   (either -O or
# # -T PREFIX  Write temporary files to PREFIX.nnnn.bam       -T is required)
#
# calmd
# # -u         uncompressed BAM output (for piping)
runs/SAM-TO-BAM/SAM-TO-BAM.sh: $(SAM) | $(BAM_DIR)
	echo $^ | \
	sed -r 's/'\
	'$(SAM_DIR)([^ ]+?).sam *'\
	'/'\
	'samtools view -bSu $(SAM_DIR)\1.sam | '\
	'samtools sort -n -O bam -o $(BAM_DIR)\1_nsort -T $(BAM_DIR)\1_nsort_tmp\n'\
	'/g' > $(RUNFILES)/sam-to-bam.txt # end
	SLURM_Array -c $(RUNFILES)/sam-to-bam.txt \
		--mail $(EMAIL) \
		-r runs/SAM-TO-BAM \
		-l $(SAMTOOLS) \
		--hold \
		-w $(ROOT_DIR)

$(BAM) : $(SAM) runs/SAM-TO-BAM/SAM-TO-BAM.sh
# Fix mate information and add the MD tag.
# # http://samtools.github.io/hts-specs/
# # MD = String for mismatching positions
# # NM = Edit distance to the reference
runs/FIXMATE/FIXMATE.sh: $(BAM) | $(BAM_DIR)
	echo $^ | \
	sed -r 's@'\
	'([^ ]+?)_nsort *'\
	'@'\
	'zcat $(FASTA) > $(TMP)/r.fa; '\
	'samtools fixmate -O bam \1_nsort /dev/stdout | '\
	'samtools sort -O bam -o - -T \1_csort_tmp | '\
	'samtools calmd -b - $(TMP)/r.fa > \1_fixed.bam\n'\
	'@g' > $(RUNFILES)/fixmate.txt # end
	SLURM_Array -c $(RUNFILES)/fixmate.txt \
		--mail $(EMAIL) \
		-r runs/FIXMATE \
		-l $(SAMTOOLS) \
		--hold \
		-w $(ROOT_DIR)

$(FIXED) : $(BAM) runs/FIXMATE/FIXMATE.sh

runs/VALIDATE-BAM/VALIDATE-BAM.sh: $(FIXED) | $(BAM_DIR)
	echo $^ | \
	sed -r 's@'\
	'([^ ]+?)_fixed.bam *'\
	'@'\
	'samtools stats \1_fixed.bam | '\
	'gzip -c > \1_fixed_stats.txt.gz\n'\
	'@g' > $(RUNFILES)/validate-bam.txt # end
	SLURM_Array -c $(RUNFILES)/validate-bam.txt \
		--mail $(EMAIL) \
		-r runs/VALIDATE-BAM \
		-l $(SAMTOOLS) \
		--hold \
		-w $(ROOT_DIR)

$(BAM_VAL) : $(FIXED) runs/VALIDATE-BAM/VALIDATE-BAM.sh

runs/MARK-DUPS/MARK-DUPS.sh: $(FIXED)
	echo $^ | \
	sed -r 's@'\
	'([^ ]+?)_fixed.bam *'\
	'@'\
	'java -Djava.io.tmpdir=$(TMP) '\
	'-jar $(PIC) MarkDuplicates '\
	'I=\1_fixed.bam '\
	'O=\1_dupmrk.bam '\
	'MAX_FILE_HANDLES_FOR_READ_ENDS_MAP=1000 '\
	'ASSUME_SORTED=true '\
	'M=\1_marked_dup_metrics.txt; '\
	'samtools index \1_dupmrk.bam\n'\
	'@g' > $(RUNFILES)/mark-dups.txt # end
	SLURM_Array -c $(RUNFILES)/mark-dups.txt \
		--mail $(EMAIL) \
		-r runs/MARK-DUPS \
		-l $(PICARD) $(SAMTOOLS) \
		--hold \
		-m 25g \
		-w $(ROOT_DIR)

$(DUPMRK) : $(FIXED) runs/MARK-DUPS/MARK-DUPS.sh

runs/VALIDATE-DUPS/VALIDATE-DUPS.sh: $(DUPMRK)
	echo $^ | \
	sed -r 's@'\
	'([^ ]+?)_dupmrk.bam *'\
	'@'\
	'samtools stats \1_dupmrk.bam | '\
	'gzip -c \1_dupmrk_stats.txt.gz\n'\
	'@g' > $(RUNFILES)/validate-dups.txt # end
	SLURM_Array -c $(RUNFILES)/validate-dups.txt \
		--mail $(EMAIL) \
		-r runs/VALIDATE-DUPS \
		-l $(SAMTOOLS) \
		--hold \
		-w $(ROOT_DIR)	

$(DUP_VAL): $(DUPMRK) runs/VALIDATE-DUPS/VALIDATE-DUPS.sh


# https://www.broadinstitute.org/gatk/documentation/article?id=3893
# # https://www.broadinstitute.org/gatk/documentation/tooldocs/org_broadinstitute_gatk_tools_walkers_haplotypecaller_HaplotypeCaller.php
# # https://www.broadinstitute.org/gatk/documentation/tooldocs/org_broadinstitute_gatk_tools_walkers_variantutils_GenotypeGVCFs.php
#
# # Note that Haplotypecaller requires an indexed bam.
# # If yours is not, use SAMtools.
#
# # If you're dealing with legacy data you may encounter legacy quality encodings.
# # If you encounter this use:
# #
# # --fix_misencoded_quality_scores
# #
# # In your GATK call. (But only on the offending libraries.)
# # https://software.broadinstitute.org/gatk/gatkdocs/org_broadinstitute_gatk_engine_CommandLineGATK.php#--fix_misencoded_quality_scores
# # https://en.wikipedia.org/wiki/FASTQ_format
#
#
# CMD="$JAVA -Djava.io.tmpdir=/data/ -jar $GATK \
#   -T HaplotypeCaller \
#   -R $REF \
#   --emitRefConfidence GVCF \
#   -ploidy 2 \
#   -I bams/${arr[0]}_dupmrk.bam \
#   -o gvcf/${arr[0]}_2n.g.vcf.gz"
#
#
# CMD="$JAVA -Djava.io.tmpdir=/data/ -jar $GATK \
#    -T HaplotypeCaller \
#    -R $REF \
#    --emitRefConfidence GVCF \
#    -ploidy 3 \
#    -I bams/${arr[0]}_dupmrk.bam \
#    -o gvcf/${arr[0]}_3n.g.vcf.gz"
#

runs/MAKE-GATK-REF/MAKE-GATK-REF.sh: $(FASTA) | $(REF_DIR)
	echo $^ | \
	sed -r 's@'\
	'(mitochondria_genome)/(.+?).fasta.gz'\
	'@'\
	'zcat \1/\2.fasta.gz > $(REF_DIR)/\2.fasta; '\
	'java -jar $(PIC) CreateSequenceDictionary '\
	'R=$(REF_DIR)/\2.fasta '\
	'O=$(REF_DIR)/\2.dict; '\
	'samtools faidx $(REF_DIR)/\2.fasta'\
	'@g' > $(RUNFILES)/make-gatk-ref.txt # end
	SLURM_Array -c $(RUNFILES)/make-gatk-ref.txt \
		--mail $(EMAIL) \
		-r runs/MAKE-GATK-REF \
		-l $(PICARD) $(SAMTOOLS) \
		--hold \
		-w $(ROOT_DIR)

$(REF_IDX): $(FASTA) runs/MAKE-GATK-REF/MAKE-GATK-REF.sh

# Pain points:
# 
# GATK is very picky as far as paths go. If it sees a relative
# path, it will use pwd. On this SLURM system, this results in
# a path that's not accessible.
#
# GATK assumes that you named your dict file with the basename
# of your file and not just appended dict on the end.
#
runs/MAKE-GVCF/MAKE-GVCF.sh: $(DUPMRK) | $(GVCF_DIR)
	echo $^ | \
	sed -r 's@'\
	'$(BAM_DIR)/([^ ]+?)_dupmrk.bam *'\
	'@'\
	'java -Djava.io.tmpdir=$(TMP) -jar $(gatk) '\
	'-T HaplotypeCaller '\
	'-R $(ROOT_DIR)/$(REF_IDX) '\
	'--emitRefConfidence GVCF '\
	'-ploidy 1 '\
	'-I $(BAM_DIR)/\1_dupmrk.bam '\
	'-o $(GVCF_DIR)/\1.g.vcf.gz\n'\
	'@g' > $(RUNFILES)/make-gvcf.txt
	SLURM_Array -c $(RUNFILES)/make-gvcf.txt \
		--mail $(EMAIL) \
		-r runs/MAKE-GVCF \
		-l $(GATK) \
		--hold \
		-m 25g \
		-w $(ROOT_DIR)

$(GVCF): $(DUPMRK) runs/MAKE-GVCF/MAKE-GVCF.sh



# CMD="$JAVA -Djava.io.tmpdir=/data/ \
#   -jar $GATK \
#   -T GenotypeGVCFs \
#   -R $REF \
#   -L Supercontig_1.$SGE_TASK_ID \
#   -V gvcfs.list \
#   -o vcfs/sc_1.$SGE_TASK_ID.vcf.gz"

help :
	@echo
	@echo "COMMANDS"
	@echo "============"
	@echo
	@echo "all"
	@echo "index" 
	@echo "help" 
	@echo "runclean.JOB_NAME"
	@echo
	@echo "PARAMETERS"
	@echo "============"
	@echo
	@echo "EMAIL     : " $(EMAIL)
	@echo "ROOT DIR  : " $(ROOT_DIR)
	@echo "TEMP DIR  : " $(TMP)
	@echo "INDEX DIR : " $(IDX_DIR)
	@echo "PREFIX    : " $(PREFIX)
	@echo "SAM DIR   : " $(SAM_DIR)
	@echo "BAM DIR   : " $(BAM_DIR)
	@echo "GENOME    : " $(FASTA)
	@echo "RUNFILES  : " $(RUNFILES)
	@echo "READS     : " $(READS)
	@echo

runclean.%:
	$(RM) -rfv runs/$*

