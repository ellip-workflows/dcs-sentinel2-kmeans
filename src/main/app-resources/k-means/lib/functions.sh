#!/bin/bash

# define the exit codes
SUCCESS=0
ERR_NO_URL=5
ERR_NO_PRD=8
ERR_NO_S2MTD=10
ERR_SNAP=15
ERR_COMPRESS=20
ERR_GDAL=25
ERR_GDAL_QL=30
ERR_GEO_QL=35
ERR_PUBLISH=40

# add a trap to exit gracefully
function cleanExit ()
{
  local retval=$?
  local msg=""
  case "${retval}" in
    ${SUCCESS}) msg="Processing successfully concluded";;
    ${ERR_NO_URL}) msg="The Sentinel-2 product online resource could not be resolved";;
    ${ERR_NO_PRD}) msg="The Sentinel-2 product online resource could not be retrieved";;
    ${ERR_NO_S2MTD}) msg="Could not find Sentinel-2 product metadata file";;
    ${ERR_SNAP}) msg="SNAP GPT failed";;
    ${ERR_GDAL}) msg="GDAL failed to convert result to tif";;
    ${ERR_GDAL_QL}) msg="GDAL failed to convert result to PNG";;
    ${ERR_COMPRESS}) msg="Failed to compress results";;
    ${ERR_GEO_QL}) msg="Failed to georeference PNG";;
    ${ERR_PUBLISH}) msg="Failed to publish the results";;
    *) msg="Unknown error";;
 esac

  [ "${retval}" != "0" ] && ciop-log "ERROR" "Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"
  exit ${retval}
}

trap cleanExit EXIT

function set_env() {

  export sourceBands="$( ciop-getparam sourceBands )"
  export upsampling="$( ciop-getparam upsampling )"
  export downsampling="$( ciop-getparam downsampling )"
  export flagDownsampling="$( ciop-getparam flagDownsampling )"
  export resampleOnPyramidLevels="$( ciop-getparam resampleOnPyramidLevels )"
  export targetResolution="$( ciop-getparam targetResolution | sed 's/m//')"
  export clusterCount="$( ciop-getparam clusterCount )"
  export iterationCount="$( ciop-getparam iterationCount )"
  export randomSeed="$( ciop-getparam randomSeed )"
  export sourceBandNames="$( ciop-getparam sourceBandNames )"
  
  export SNAP_HOME=/opt/snap
  export PATH=${SNAP_HOME}/bin:${PATH}
  export SNAP_VERSION=$( cat ${SNAP_HOME}/VERSION.txt )

  return 0
  
}

function main() {

  set_env || exit $?

  input=$1
  
  cd ${TMPDIR}

  num_steps=7

  ciop-log "INFO" "(1 of ${num_steps}) Resolve Sentinel-2 online resource"
  online_resource="$( opensearch-client ${input} enclosure )"
  [[ -z ${online_resource} ]] && return ${ERR_NO_URL}

  ciop-log "INFO" "(2 of ${num_steps}) Retrieve Sentinel-2 product from ${online_resource}"
  local_s2="$( ciop-copy -o ${TMPDIR} ${online_resource} )"
  [[ -z ${local_s2} ]] && return ${ERR_NO_PRD} 

  # find MTD file in ${local_s2}
  s2mtd="$( find ${local_s2} -name "MTD_MSIL1C.xml" )"

  [[ -z "${s2mtd}" ]] && s2mtd="$( find ${local_s2} -name "S2?_OPER_MTD_SAFL1C*.xml" )"   
  
  [[ -z "${s2mtd}" ]] && return ${ERR_NO_S2MTD}

  out=${local_s2}_result
  SNAP_REQUEST=${_CIOP_APPLICATION_PATH}/k-means/etc/snap_request.xml

  
  ciop-log "INFO" "(3 of ${num_steps}) Invoke SNAP GPT"

  gpt ${SNAP_REQUEST} \
    -Pin=${s2mtd} \
    -Pout=${out} \
    -PsourceBands="${sourceBands}" \
    -Pupsampling="${upsampling}" \
    -Pdownsampling="${downsampling}" \
    -PflagDownsampling="${flagDownsampling}" \
    -PresampleOnPyramidLevels="${resampleOnPyramidLevels}" \
    -PtargetResolution="${targetResolution}" \
    -PclusterCount=${clusterCount} \
    -PiterationCount=${iterationCount} \
    -PrandomSeed=${randomSeed} \
    -PsourceBandNames=${sourceBandNames} 1>&2 || return ${ERR_SNAP} 

  ciop-log "INFO" "(4 of ${num_steps}) Compress results"  
  tar -C ${TMPDIR} -czf ${out}.tgz $( basename ${out}).dim $( basename ${out}).data || return ${ERR_COMPRESS}
  ciop-publish -m ${out}.tgz || return ${ERR_PUBLISH}  
   
  ciop-log "INFO" "(5 of ${num_steps}) Convert to geotiff"
  # Convert to GeoTIFF
  gdal_translate ${out}.data/class_indices.img ${out}.tif || return ${ERR_GDAL}
  ciop-publish -m ${out}.tif || return ${ERR_PUBLISH}
  
  ciop-log "INFO" "(6 of ${num_steps}) Convert to PNG"
  gdal_translate -of PNG -a_nodata 0 -scale 0 1 0 255 ${out}.tif ${out}.png || return ${ERR_GDAL_QL}
  ciop-publish -m ${out}.png || return ${ERR_PUBLISH}
  
  listgeo -tfw ${out}.tif || return ${ERR_GEO_QL}
  mv ${out}.tfw ${out}.pngw
  ciop-publish -m ${out}.pngw || return ${ERR_PUBLISH}
 
  ciop-log "INFO" "(7 of ${num_steps}) Clean up" 
  # clean-up
  rm -fr ${local_s2}
  rm -fr ${out}*

}
