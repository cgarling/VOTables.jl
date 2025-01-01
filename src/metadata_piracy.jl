# XXX: should upstream to MetadataArrays
import DataAPI: metadata, metadatasupport, colmetadata, colmetadatasupport
metadatasupport(::Type{<:MetadataArray}) = (read=true, write=false)
metadata(ma::MetadataArray) = MetadataArrays.metadata(ma)
