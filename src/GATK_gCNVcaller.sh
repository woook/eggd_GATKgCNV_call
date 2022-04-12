#!/bin/bash
# GATK_gCNVcaller_dev
#
# Any code outside of main() (or any entry point you may add) is
# ALWAYS executed, followed by running the entry point itself.

# Exit at any point if there is any error and output each line as it is executed (for debugging)
set -e -x -o pipefail

main() {

    echo "Installing packages"
    mark-section "Installing packages"
    sudo dpkg -i sysstat*.deb
    sudo dpkg -i parallel*.deb
    cd packages
    pip install -q pytz-* python_dateutil-* pysam-* numpy-* pandas-* pybedtools-* PyVCF-*
    cd ..

    # Load the GATK docker image
    mark-section "Loading GATK Docker image"
    dx download "$GATK_docker" -o GATK.tar.gz
    docker load -i GATK.tar.gz
    export GATK_image=$(docker images --format="{{.Repository}} {{.ID}}" | grep "^broad" | cut -d' ' -f2)
    export $CollectReadCounts_args
    export $PostprocessGermlineCNVCalls_args

    ## Create folder to collect input files:
    mkdir inputs
    # Prior probabilities tsv
    if [[ ! -z $prior_prob ]]; then
        echo "Prior prob file is provided as '$prior_prob'"
        dx download "$prior_prob" -o inputs/prior_prob.tsv
    else
        mv prior_prob.tsv inputs/
    fi

    cd inputs
    mkdir beds
    mark-section "Downloading input bed files"
    # Intervals file (preprocessed bed from GATK_prep)
    dx download "$interval_list" -o beds/preprocessed.interval_list
    # Annotation tsv (from GATK_prep)
    dx download "$annotation_tsv" -o beds/annotated_intervals.tsv

    mkdir bams
    cd bams
    ## Download all input bam and bai files
    mark-section "Downloading input bam&bai files"
    for i in ${!bambis[@]}
    do
        dx download "${bambis[$i]}"
    done
    cd ..
    echo "All input files have downloaded to inputs/"
    cd ..

    if $debug_fail_start; then exit 1; fi

    # 1. Run CollectReadCounts:
    # takes a bam file at a time (and its index file) and the target.bed
    echo "Running CollectReadCounts for all input bams"
    mark-section "CollectReadCounts"
        # mkdir inputs/base_counts
        # for bam_file in inputs/bams/*.bam
        # do
        #     sample_file=$( basename $bam_file )
        #     sample_name="${sample_file%.bam}"
        #     echo $sample_name

        #     time docker run -v /home/dnanexus/inputs:/data broadinstitute/gatk:4.1.2.0 gatk CollectReadCounts \
        #         -I /data/bams/${sample_file} \
        #         -L /data/beds/preprocessed.interval_list -imr OVERLAPPING_ONLY \
        #         --format TSV \
        #         -O /data/base_counts/${sample_name}_basecount.tsv
        #     # outputs a single tsv file per sample
        # done

    mkdir inputs/base_counts
    find inputs/bams/ -name "*.bam" | parallel -I filename --max-args 1 --jobs 8 'sample_file=$( basename filename ); sample_name="${sample_file%.bam}"; echo $sample_name; /usr/bin/time -v sudo docker run -v /home/dnanexus/inputs:/data $GATK_image gatk CollectReadCounts -I /data/bams/${sample_file} -L /data/beds/preprocessed.interval_list -imr OVERLAPPING_ONLY ${CollectReadCounts_args} -O /data/base_counts/${sample_name}_basecount.hdf5'

    # prepare a batch_input string that has all sample_basecount.tsv file as an input
    batch_input=""
    for base_count in inputs/base_counts/*_basecount.*; do
        sample_file=$( basename $base_count )
        batch_input+="--input /data/base_counts/${sample_file} "
    done

    # C. Run FilterIntervals:
    echo "Running FilterIntervals for the preprocessed intervals with sample basecounts"
    mark-section "FilterIntervals"
    /usr/bin/time -v docker run -v /home/dnanexus/inputs:/data $GATK_image gatk FilterIntervals \
        -L /data/beds/preprocessed.interval_list -imr OVERLAPPING_ONLY \
        --annotated-intervals /data/beds/annotated_intervals.tsv \
        $batch_input  $FilterIntervals_args \
        -O /data/beds/filtered.interval_list

    echo "Identifying excluded intervals from CNV calling on this run"
    bedtools intersect -v -a <(tail +88 inputs/beds/preprocessed.interval_list | sort) \
        -b <(tail +88 inputs/beds/filtered.interval_list | sort) > excluded_intervals.bed
    wc -l excluded_intervals.bed

    # 2. Run DetermineGermlineContigPloidy:
    # takes the base count tsv-s from the previous step, optional target_bed, and a contig plody priors tsv
    echo "Running DetermineGermlineContigPloidy for the calculated basecounts"
    mark-section "DetermineGermlineContigPloidy"
    mkdir inputs/ploidy-dir
    /usr/bin/time -v docker run -v /home/dnanexus/inputs:/data $GATK_image gatk DetermineGermlineContigPloidy \
        -L /data/beds/filtered.interval_list -imr OVERLAPPING_ONLY \
        $batch_input \
        --contig-ploidy-priors /data/prior_prob.tsv --output-prefix ploidy \
        -O /data/ploidy-dir
    # outputs a ploidy model and ploidy-calls for each sample

    # 3. Run GermlineCNVCaller:
    # takes the base count tsv-s, target bed and contig ploidy calls from the previous steps
    echo "Running GermlineCNVCaller for the calculated basecounts using the generated ploidy file"
    mark-section "GermlineCNVCaller"
    mkdir inputs/gCNV-dir
    /usr/bin/time -v docker run -v /home/dnanexus/inputs:/data $GATK_image gatk GermlineCNVCaller \
        $batch_input --run-mode COHORT  $GermlineCNVCaller_args \
        -L /data/beds/filtered.interval_list -imr OVERLAPPING_ONLY \
        --annotated-intervals /data/beds/annotated_intervals.tsv \
        --contig-ploidy-calls /data/ploidy-dir/ploidy-calls/ --output-prefix CNV \
        -O /data/gCNV-dir
    # outputs a CNVcalling model and copy ratio files for each sample

    # 4. Run PostprocessGermlineCNVCalls:
    # takes CNV-model in, spits vcfs out
    echo "Running PostprocessGermlineCNVCalls"
        # i=0
        # for bam_file in inputs/bams/*.bam
        # do
        #     sample_file=$( basename $bam_file )
        #     sample_name="${sample_file%.bam}"
        #     echo $sample_name

        #     docker run -v /home/dnanexus/inputs:/data broadinstitute/gatk:4.1.2.0 gatk PostprocessGermlineCNVCalls \
        #     --contig-ploidy-calls /data/ploidy-dir/ploidy-calls \
        #     --calls-shard-path /data/gCNV-dir/CNV-calls/ \
        #     --model-shard-path /data/gCNV-dir/CNV-model/ \
        #     --sample-index $i \
        #     --autosomal-ref-copy-number 2 \
        #     --allosomal-contig X \
        #     --allosomal-contig Y \
        #     --output-genotyped-intervals /data/vcfs/${sample_name}_intervals.vcf \
        #     --output-genotyped-segments /data/vcfs/${sample_name}_segments.vcf
        
        #     ((i=i+1))
        # done

        # Required Arguments for 4.2.5.0: (4.2 onwards)
        ## --calls-shard-path <File>     List of paths to GermlineCNVCaller call directories.  This argument must be specified atleast once. Required. 
        ## --contig-ploidy-calls <File>  Path to contig-ploidy calls directory (output of DetermineGermlineContigPloidy). Required. 
        ## --model-shard-path <File>     List of paths to GermlineCNVCaller model directories.  This argument must be specified atleast once. Required. 
        # --output-denoised-copy-ratios <File> Output denoised copy ratio file.  Required. 
        # --output-genotyped-intervals <File>  Output intervals VCF file.  Required. 
        # --output-genotyped-segments <File> Output segments VCF file.  Required. 

    mark-section "PostprocessGermlineCNVCalls"
    mkdir inputs/vcfs
    sample_num=$(ls inputs/bams/*.bam | wc -l)
    index=$(expr $sample_num - 1)
    parallel --jobs 8 '/usr/bin/time -v docker run -v /home/dnanexus/inputs:/data $GATK_image \
        gatk PostprocessGermlineCNVCalls --sample-index {} \
        ${PostprocessGermlineCNVCalls_args} \
        --autosomal-ref-copy-number 2 --allosomal-contig X --allosomal-contig Y \
        --contig-ploidy-calls /data/ploidy-dir/ploidy-calls \
        --calls-shard-path /data/gCNV-dir/CNV-calls --model-shard-path /data/gCNV-dir/CNV-model \
        --output-genotyped-intervals /data/vcfs/sample_{}_intervals.vcf \
        --output-genotyped-segments /data/vcfs/sample_{}_segments.vcf \
        --output-denoised-copy-ratios /data/vcfs/sample_{}_denoised_copy_ratios.tsv \
    ' ::: $(seq 0 1 $index)

    # Rename output vcf files based on the sample they contain information about
    find inputs/vcfs/ -name "*_segments.vcf" | parallel -I{} --max-args 1 --jobs 8 ' \
        sample_file=$( basename {} ); file_name="${sample_file%_segments.vcf}"; \
        sample_name=$(bcftools view {} -h | tail -n 1 | cut -f 10 ); \
        mv inputs/vcfs/$file_name"_denoised_copy_ratios.tsv" inputs/vcfs/$sample_name"_denoised_copy_ratios.tsv"; \
        mv inputs/vcfs/$file_name"_segments.vcf" inputs/vcfs/$sample_name"_segments.vcf"; \
        mv inputs/vcfs/$file_name"_intervals.vcf" inputs/vcfs/$sample_name"_intervals.vcf" \
    '

    echo "CNV calling finished successfully"
    ## Create output directories
    # and move result files into outdir to be uploaded
    vcf_dir=out/result_files/CNV_vcfs && mkdir -p ${vcf_dir}
    cp inputs/vcfs/*.vcf ${vcf_dir}/
    # copy_ratio_dir=out/result_files/CNV_copy_ratios && mkdir -p ${copy_ratio_dir}
    # cp inputs/vcfs/*_denoised_copy_ratios.tsv ${copy_ratio_dir}
    summary_dir=out/result_files/CNV_summary && mkdir -p ${summary_dir}
    cp excluded_intervals.bed ${summary_dir}/$run_name"_excluded_intervals.bed"

    # Move result files into outdir to be uploaded
    # outdir=out/result_files && mkdir -p ${outdir}
    # mv inputs/ploidy-dir/* ${outdir}/
    # cp -r inputs/gCNV-dir/CNV-calls ${outdir}/

    if $toAnnotate; then
        # Download exons file (list of exon positions and transcript ID bed)
        if [[ ! -z $exon_list ]]; then
            echo "Exon annotation file is provided as '$exon_list_prefix'"
            dx download "$exon_list" -o inputs/beds/exon.list

            mark-section "Annotating calls"
            # Annotate CNV calls with gene, transcript and exon number information
            # and calculate per run frequency of calls
            echo "Running the run-level annotation script"
            python3 summarise_calls.py inputs/vcfs/ inputs/beds/exon.list
            mv Annotated_CNV_summary.tsv ${summary_dir}/$run_name"_annotated_CNV_summary.tsv"
            mv CNV_counts.tsv ${summary_dir}/$run_name"_CNV_counts.tsv"
        else
            echo "Exon annotation file was not provided"
        fi
    fi

    if $toVisualise; then
        vis_dir=out/result_files/CNV_visualisation && mkdir -p ${vis_dir}
        # Generate bed file from copy ratio files for viewing all samples in IGV
        echo "Generating gcnv bed files for all sample copy ratios"
        mark-section "Visualising calls"
        denoised_copy_ratio_files=$(find inputs/vcfs/ -name "*_denoised_copy_ratios.tsv")
        python3 generate_gcnv_bed.py --copy_ratios "$denoised_copy_ratio_files" -s \
        --run "$run_name"

        mv ./"$run_name"*.gcnv.bed.gz* "${summary_dir}"/
        mv ./*.gcnv.bed.gz* "${vis_dir}"/
    fi

    echo "All scripts finished successfully, uploading output files to dx"
    if $debug_fail_end; then exit 1; fi

    # Upload output files
    dx-upload-all-outputs --parallel

}
