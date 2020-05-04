#!/usr/bin/env nextflow

nextflow.preview.dsl=2

/*  Check if all necessary input parameters are present */
if ( (!params.fastq_path && !params.bam_path && !params.gvcf_path ) && !params.vcf_path){
  exit 1, "Please provide either a 'fastq_path', 'bam_path', 'gvcf_path' or 'vcf_path'. You can provide these parameters either in the <analysis_name>.config file or on the commandline (add -- in front of the parameter)."
}

if (!params.out_dir){
  exit 1, "No 'out_dir' parameter found in <analysis_name>.config file or on the commandline (add -- in front of the parameter)."
}

if (!params.genome){
  exit 1, "No 'genome' parameter found in in <analysis_name>.config file or on the commandline (add -- in front of the parameter)."
}
if ( !params.genomes[params.genome] || !params.genomes[params.genome].fasta ){
  exit 1, "'genome' parameter ${params.genome} not found in list of genomes in resources.config!"
}

if ( !params.genomes[params.genome].interval_list ){
  exit 1, "No interval_list found for ${params.genome}!"
}

workDir = params.out_dir

params.genome_fasta = params.genomes[params.genome].fasta
params.scatter_interval_list = params.genomes[params.genome].interval_list
params.genome_known_sites = params.genomes[params.genome].gatk_known_sites ? params.genomes[params.genome].gatk_known_sites : null
params.genome_dbsnp = params.genomes[params.genome].dbsnp ? params.genomes[params.genome].dbsnp : null
params.genome_dbnsfp = params.genomes[params.genome].dbnsfp ? params.genomes[params.genome].dbnsfp : null
params.genome_variant_annotator_db = params.genomes[params.genome].cosmic ? params.genomes[params.genome].cosmic : null
params.genome_snpsift_annotate_db = params.genomes[params.genome].gonl ? params.genomes[params.genome].gonl : null
params.genome_freec_chr_len = params.genomes[params.genome].freec_chr_len ? params.genomes[params.genome].freec_chr_len : null
params.genome_freec_chr_files = params.genomes[params.genome].freec_chr_files ? params.genomes[params.genome].freec_chr_files : null
params.genome_freec_mappability = params.genomes[params.genome].freec_mappability ? params.genomes[params.genome].freec_mappability : null

include './NextflowModules/Utils/fastq.nf'
include extractBamFromDir from './NextflowModules/Utils/bam.nf'
include extractGVCFFromDir from './NextflowModules/Utils/gvcf.nf'
include extractVCFFromDir from './NextflowModules/Utils/vcf.nf'
include premap_QC from './workflows/premap_QC.nf' params(params)
include postmap_QC from './workflows/postmap_QC.nf' params(params)
include summary_QC from './workflows/summary_QC.nf' params(params)
include bwa_mapping from './workflows/bwa_mapping.nf' params(params)
include gatk_bqsr from './workflows/gatk_bqsr.nf' params(params)
include gatk_germline_calling from './workflows/gatk_germline_calling.nf' params(params)
include gatk_variantfiltration from './workflows/gatk_variantfiltration.nf' params(params)
include snpeff_gatk_annotate from './workflows/snpeff_gatk_annotate.nf' params(params)
include sv_calling from './workflows/sv_calling.nf' params(params)
include cnv_calling from './workflows/cnv_calling.nf' params(params)

workflow {
  main :
    def input_fastqs
    def input_bams
    def input_gvcf

    // Gather input FastQ's
    if (params.fastq_path){
      input_fastqs = extractFastqFromDir(params.fastq_path)
    }
    // Gather input BAM files
    if (params.bam_path){
      input_bams = extractBamFromDir(params.bam_path)
    }
    // Gather input GVCF files
    if (params.gvcf_path) {
      input_gvcf = extractGVCFFromDir(params.gvcf_path)
    }
    //Gather input VCF files
    if(params.vcf_path) {
      input_vcf = extractVCFFromDir(params.vcf_path)
    }

    // Run mapping & premap_QC only when a fastq_path is provided
    if (params.fastq_path){
      // Optionally run pre mapping QC
      if (params.premapQC) { premap_QC(input_fastqs) }
      bwa_mapping(input_fastqs)
    }

    // Create a channel containing the bam files from the bwa_mapping step and/or the bam files in bam_path
    if ( bwa_mapping.out && params.bam_path ){
      input_bams = bwa_mapping.out.mix( input_bams )
    }else if ( bwa_mapping.out ){
      input_bams = bwa_mapping.out
    }

    // Optionally run post mapping QC
    if (params.postmapQC && input_bams) { postmap_QC( input_bams )}

    // // Depending on whether input_bams and/or input_gvcf were provide start from gatk_bqsr or directly from gatk_germline_calling.
    // // gatk_germline_calling supports both bam and/or gvcf input (one of the channels can be empty)
    if (params.germlineCalling){
      if (input_bams && input_gvcf){
        gatk_bqsr( input_bams )
        gatk_germline_calling(gatk_bqsr.out, input_gvcf )
      }else if(input_bams){
        gatk_bqsr( input_bams )
        gatk_germline_calling(gatk_bqsr.out, Channel.empty() )
      }else if(input_gvcf){
        gatk_germline_calling(Channel.empty(), input_gvcf)
      }
    }

    //Run variant filtration on generated vcfs or input vcfs
    if (params.variantFiltration){
      if( gatk_germline_calling.out ){
        gatk_variantfiltration(gatk_germline_calling.out[0])
      }else if (input_vcf){
        gatk_variantfiltration(
          input_vcf.map{
            id, vcf, idx -> [id, 'NA', vcf, idx, 'NA']
          }
        )
      }
    }

    //Run variant annotation on filtered vcfs or input vcfs
    if (params.variantAnnotation){
      if (gatk_variantfiltration.out){
        snpeff_gatk_annotate(gatk_variantfiltration.out)
      }else if(input_vcf){
        snpeff_gatk_annotate(input_vcf)
      }
    }

    // Run summary_QC only when both pre- and post-mapping QC are finished.
    if (params.premapQC && params.postmapQC && input_fastqs && input_bams){
      summary_QC( premap_QC.out
        .mix(postmap_QC.out[0]).collect()
        .mix(postmap_QC.out[1]).collect()
      )
    }else if (params.premapQC && input_fastqs){
      summary_QC(premap_QC.out.collect())
    }else if (params.postmapQC  && input_bams){
      summary_QC(postmap_QC.out[0].collect())
    }

    // Run sv calling only when either bam-files or fastq files were provided as input and svCalling is true
    if (params.svCalling && input_bams ){
      sv_calling(input_bams)
    }

    // Run cnv calling only when either bam-files or fastq files were provided as input and cnvCalling is true
    if (params.cnvCalling && input_bams){
      cnv_calling(input_bams)
    }
}
