
type Dataset
    ptr::Ptr{GDAL.GDALDatasetH}

    function Dataset(ptr::Ptr{GDAL.GDALDatasetH})
        dataset = new(ptr) # number of bands
        finalizer(dataset, nullify)
        dataset
    end
end

"""
Close GDAL dataset.

For non-shared datasets (opened with `GDALOpen()`) the dataset is closed
using the C++ "delete" operator, recovering all dataset related resources.

For shared datasets (opened with `GDALOpenShared()`) the dataset is
dereferenced, and closed only if the referenced count has dropped below 1.
"""
function close(dataset::Dataset)
    GDAL.close(dataset.ptr)
    dataset.ptr = C_NULL
end

"""
Delete named dataset.

The driver will attempt to delete the named dataset in a driver specific
fashion. Full featured drivers will delete all associated files, database
objects, or whatever is appropriate. The default behaviour when no driver
specific behaviour is provided is to attempt to delete the passed name as a
single file.

It is unwise to have open dataset handles on this dataset when it is deleted.
"""
delete(dataset::Dataset, filename::AbstractString) =
    GDAL.deletedataset(dataset.ptr, filename)

"""
Rename a dataset.

This may including moving the dataset to a new directory or filesystem.

It is unwise to have open dataset handles on this dataset when it is being
renamed.
"""
rename(dataset::Dataset,
       newname::AbstractString,
       oldname::AbstractString) =
    GDAL.renamedataset(dataset.ptr, newname, oldname)

"Copy the files associated with a dataset."
copy(dataset::Dataset,
     newname::AbstractString,
     oldname::AbstractString) =
    GDAL.copydatasetfiles(dataset.ptr, newname, oldname)

"""
Copy all dataset raster data.

This function copies the complete raster contents of one dataset to another
similarly configured dataset. The source and destination dataset must have the
same number of bands, and the same width and height. The bands do not have to
have the same data type.

This function is primarily intended to support implementation of driver
specific `CreateCopy()` functions. It implements efficient copying, in
particular "chunking" the copy in substantial blocks and, if appropriate,
performing the transfer in a pixel interleaved fashion.

Currently the only papszOptions value supported are : "INTERLEAVE=PIXEL" to
force pixel interleaved operation and "COMPRESSED=YES" to force alignment on
target dataset block sizes to achieve best compression. More options may be
supported in the future.
"""
copy{T <: AbstractString}(source::Dataset,
                          dest::Dataset,
                          options::Vector{T}) =
    GDAL.datasetcopywholeraster(source.ptr, dest.ptr,
                                Ptr{Ptr{UInt8}}(pointer(options)),
                                C_NULL, C_NULL)

"""
Create a copy of a dataset.

This method will attempt to create a copy of a raster dataset with the
indicated filename, and in this drivers format. Band number, size, type,
projection, geotransform and so forth are all to be copied from the
provided template dataset.

Note: many sequential write once formats (such as JPEG and PNG) don't implement
the `Create()` method but do implement this `CreateCopy()` method. If the
driver doesn't implement `CreateCopy()`, but does implement `Create()` then the
default `CreateCopy()` mechanism built on calling `Create()` will be used.

It is intended that `CreateCopy()` will often be used with a source dataset
which is a virtual dataset allowing configuration of band types, and other
information without actually duplicating raster data (see the VRT driver). This
is what is done by the gdal_translate utility for example.

This function will validate the creation option list passed to the driver
with the `GDALValidateCreationOptions()` method. This check can be disabled by
defining the configuration option `GDAL_VALIDATE_CREATION_OPTIONS=NO`.

After you have finished working with the returned dataset, it is required to
close it with `GDALClose()`. This does not only close the file handle, but also
ensures that all the data and metadata has been written to the dataset
(`GDALFlushCache()` is not sufficient for that purpose).

In some situations, the new dataset can be created in another process through
the GDAL API Proxy mechanism.

### Parameters
* `filename`      the name for the new dataset. UTF-8 encoded.
* `dataset`       the dataset being duplicated.
* `strict`        `TRUE` if the copy must be strictly equivelent, or more
normally `FALSE` if the copy may adapt as needed for the output format.
* `options`       additional format dependent options controlling creation
of the output file. `The APPEND_SUBDATASET=YES` option can be specified to
avoid prior destruction of existing dataset.

### Returns
a pointer to the newly created dataset (may be read-only access).
"""
function createcopy(filename::AbstractString,
                    dataset::Dataset,
                    driver::Driver,
                    strict::Bool = false)
    Dataset(GDAL.createcopy(driver.ptr, filename, dataset.ptr, strict,
                            C_NULL, C_NULL, C_NULL))
end

function createcopy{T <: AbstractString}(
                    filename::AbstractString,
                    dataset::Dataset,
                    driver::Driver,
                    options::Vector{T},
                    strict::Bool = false)
    Dataset(GDAL.createcopy(driver.ptr, filename, dataset.ptr, strict,
                            Ptr{Ptr{UInt8}}(pointer(options)),
                            C_NULL, C_NULL))
end

function createcopy(f::Function, args...)
    ds = createcopy(args...)
    try
        f(ds)
    finally
        close(ds)
    end
end

function create(filename::AbstractString,
                width::Int,
                height::Int,
                nbands::Int,
                dtype::DataType,
                drivername::AbstractString,
                options::Vector{ASCIIString} = Vector{ASCIIString}())
    Dataset(GDAL.create(GDAL.getdriverbyname(drivername), filename,
                        width, height, nbands, _gdaltype(dtype),
                        Ptr{Ptr{UInt8}}(pointer(options))))
end

function create(f::Function, args...)
    ds = create(args...)
    try
        f(ds)
    finally
        close(ds)
    end
end

"""
Open a raster file as a GDALDataset.

This function will try to open the passed file, or virtual dataset name by
invoking the Open method of each registered `GDALDriver` in turn. The first
successful open will result in a returned dataset. If all drivers fail then
`NULL` is returned and an error is issued.

Several recommendations:

If you open a dataset object with `GA_Update` access, it is not recommended to
open a new dataset on the same underlying file. The returned dataset should
only be accessed by one thread at a time. To use it from different threads,
you must add all necessary code (mutexes, etc.) to avoid concurrent use of the
object. (Some drivers, such as GeoTIFF, maintain internal state variables that
are updated each time a new block is read, preventing concurrent use.)

Starting with GDAL 1.6.0, if `GDALOpenShared()` is called on the same
`pszFilename` from two different threads, a different `GDALDataset` object will
be returned as it is not safe to use the same dataset from different threads,
unless the user does explicitly use mutexes in its code.

For drivers supporting the VSI virtual file API, it is possible to open a file
in a `.zip` archive (see `VSIInstallZipFileHandler()`), a `.tar/.tar.gz/.tgz`
archive (see `VSIInstallTarFileHandler()`), or a HTTP / FTP server
(see `VSIInstallCurlFileHandler()`)

In some situations (dealing with unverified data), the datasets can be opened
in another process through the GDAL API Proxy mechanism.

See also: `GDALOpenShared()`, `GDALOpenEx()`

### Parameters
* `filename`  the name of the file to access. In the case of exotic drivers
this may not refer to a physical file, but instead contain information for the
driver on how to access a dataset. It should be in UTF-8 encoding.
* `access`      the desired access, either `GA_Update` or `GA_ReadOnly`. Many
drivers support only read only access.
"""
function read(filename::AbstractString, shared::Bool = false)
    if shared
        dataset = GDAL.openshared(filename, GDAL.GA_ReadOnly)
    else
        dataset = GDAL.open(filename, GDAL.GA_ReadOnly)
    end
    Dataset(dataset)
end

function read(f::Function, args...)
    ds = read(args...)
    try
        f(ds)
    finally
        close(ds)
    end
end

function update(filename::AbstractString, shared::Bool = false)
    if shared
        dataset = GDAL.openshared(filename, GDAL.GA_Update)
    else
        dataset = GDAL.open(filename, GDAL.GA_Update)
    end
    Dataset(dataset)
end

function update(f::Function, args...)
    ds = update(args...)
    try
        f(ds)
    finally
        close(ds)
    end
end

function write(filename::AbstractString,
               dataset::Dataset,
               strict::Bool = false,
               options::Vector{ASCIIString} = Vector{ASCIIString}())
    checknull(dataset) && error("Can't write closed dataset")
    close(createcopy(driver(dataset.ptr), filename,
                     dataset.ptr, strict, options))
end

function write(dataset::Dataset,
               filename::AbstractString,
               driver::Driver,
               strict::Bool = false,
               options::Vector{ASCIIString} = Vector{ASCIIString}())
    checknull(dataset) && error("Can't write closed dataset")
    close(createcopy(Driver.ptr, filename,
                     dataset.ptr, strict, options))
end

function write(dataset::Dataset,
               filename::AbstractString,
               drivername::AbstractString,
               strict::Bool = false,
               options::Vector{ASCIIString} = Vector{ASCIIString}())
    checknull(dataset) && error("Can't write closed dataset")
    close(createcopy(GDAL.getdriverbyname(name), filename,
                     dataset.ptr, strict, options))
end

function write(f::Function, args...)
    ds = write(args...)
    try
        f(ds)
    finally
        close(ds)
    end
end

"Fetch raster width in pixels."
width(dataset::Dataset) = GDAL.getrasterxsize(dataset.ptr)

"Fetch raster height in pixels."
height(dataset::Dataset) = GDAL.getrasterysize(dataset.ptr)

"Fetch the number of raster bands on this dataset."
nband(dataset::Dataset) = GDAL.getrastercount(dataset.ptr)

"Fetch the driver that the dataset was created with"
driver(dataset::Dataset) = Driver(GDAL.getdatasetdriver(dataset.ptr))

"Fetch a band object for a dataset from its index"
fetchband(dataset::Dataset, i::Integer) =
    RasterBand(GDAL.getrasterband(dataset.ptr, i))

"""
Add a band to a dataset.

This method will add a new band to the dataset if the underlying format
supports this action. Most formats do not.

Note that the new `GDALRasterBand` is not returned. It may be fetched after
successful completion of the method through `GetRasterBand(GetRasterCount())`
as the newest band will always be the last band.

### Parameters
* `eType`           the data type of the pixels in the new band.
* `options`    a list of NAME=VALUE option strings. The supported options
are format specific. `NULL` may be passed by default.
"""
addband(dataset::Dataset, eType::GDAL.GDALDataType) =
    GDAL.addband(dataset.ptr, eType, C_NULL)

addband{T <: AbstractString}(dataset::Dataset, eType::GDAL.GDALDataType,
                             options::Vector{T}) =
    GDAL.addband(dataset.ptr, eType, Ptr{Ptr{UInt8}}(pointer(options)))

"""
Fetch files forming dataset.

Returns a list of files believed to be part of this dataset. If it returns an
empty list of files it means there is believed to be no local file system files
associated with the dataset (for instance a virtual dataset). The returned file
list is owned by the caller and should be deallocated with `CSLDestroy()`.

The returned filenames will normally be relative or absolute paths depending on
the path used to originally open the dataset. The strings will be UTF-8 encoded
"""
filelist(dataset::Dataset) =
    loadstringlist(GDAL.C.GDALGetFileList(Ptr{Void}(dataset.ptr)))

"""
Fetch the affine transformation coefficients.

Fetches the coefficients for transforming between pixel/line (P,L) raster
space, and projection coordinates (Xp,Yp) space.

```julia
   Xp = padfTransform[0] + P*padfTransform[1] + L*padfTransform[2];
   Yp = padfTransform[3] + P*padfTransform[4] + L*padfTransform[5];
```

In a north up image, `padfTransform[1]` is the pixel width, and
`padfTransform[5]` is the pixel height. The upper left corner of the upper left
pixel is at position `(padfTransform[0],padfTransform[3])`.

The default transform is `(0,1,0,0,0,1)` and should be returned even when a
`CE_Failure` error is returned, such as for formats that don't support
transformation to projection coordinates.

### Parameters
* `buffer`   a six double buffer into which the transformation will be placed.

### Returns
`CE_None` on success, or `CE_Failure` if no transform can be fetched.
"""
function getgeotransform!(dataset::Dataset, buffer::Vector{Cdouble})
    @assert length(buffer) == 6
    result = GDAL.getgeotransform(dataset.ptr, pointer(buffer))
    (result == GDAL.CE_Failure) && error("Failed to get geotransform from raster")
    buffer
end

getgeotransform(dataset::Dataset) =
    getgeotransform!(dataset, Array(Cdouble, 6))

"Set the affine transformation coefficients."
function setgeotransform!(dataset::Dataset, transform::Vector{Cdouble})
    @assert length(buffer) == 6
    result = GDAL.setgeotransform(dataset.ptr, pointer(transform))
    (result == GDAL.CE_Failure) && error("Failed to transform raster dataset")
end

"Get number of GCPs for this dataset. Zero if there are none."
ngcp(dataset::Dataset) = GDAL.getgcpcount(dataset.ptr)

"""
Fetch the projection definition string for this dataset in OpenGIS WKT format.

It should be suitable for use with the OGRSpatialReference class. When a
projection definition is not available an empty (but not `NULL`) string is
returned.

See also: http://www.gdal.org/ogr/osr_tutorial.html
"""
projWKT(dataset::Dataset) = GDAL.getprojectionref(dataset.ptr)

"Set the projection reference string for this dataset."
function setprojection!(dataset::Dataset, projstring::AbstractString)
    result = GDAL.setprojection(dataset.ptr, projstring)
    (result == GDAL.CE_Failure) && error("Could not set projection")
end

function Base.show(io::IO, dataset::Dataset)
    if checknull(dataset)
        print(io, "Closed Dataset")
    else
        nband_ = nband(dataset)
        println(io, "GDAL Dataset ($(driver(dataset)))")
        print(io, "\nFile(s): ")
        for (i,filename) in enumerate(filelist(dataset))
            if i % 4 == 0 println() end
            print(io, "$filename ")
        end
        print(io, "\nDataset (width x height): ")
        println(io, "$(width(dataset)) x $(height(dataset)) (pixels)")
        for i in 1:min(nband_, 5)
            println(io, "  $(fetchband(dataset, i))")
        end
        nband_ > 5 && println(io, "  ...")
        print(io, "Number of bands: $(nband_)")
    end
end

# "Fetch a format specific internally meaningful handle."
# _getinternalhandle(dataset::GDALDatasetH, request::Ptr{UInt8}) =
#     GDALGetInternalHandle(dataset, request)::Ptr{Void}

# """
# Add one to dataset reference count. The reference is one after instantiation.

# ### Returns
# the post-increment reference count.
# """
# _referencedataset(dataset::GDALDatasetH) = GDALReferenceDataset(dataset)::Cint

# """
# Subtract one from dataset reference count. The reference is one after
# instantiation. Generally when the reference count has dropped to zero the
# dataset may be safely deleted (closed).

# ### Returns
# the post-decrement reference count.
# """
# _dereferencedataset(dataset::GDALDatasetH) =
#     GDALDereferenceDataset(dataset)::Cint

# """
# Build raster overview(s).

# If the operation is unsupported for the indicated dataset, then CE_Failure is
# returned, and CPLGetLastErrorNo() will return CPLE_NotSupported.

# ### Parameters
# * `pszResampling`   one of "NEAREST", "GAUSS", "CUBIC", "AVERAGE", "MODE",
# "AVERAGE_MAGPHASE" or "NONE" controlling the downsampling method applied.
# * `nOverviews`      number of overviews to build.
# * `panOverviewList` the list of overview decimation factors to build.
# * `nListBands`      number of bands to build overviews for in `panBandList`.
# Build for all bands if this is 0.
# * `panBandList`     list of band numbers.
# * `pfnProgress`     a function to call to report progress, or `NULL`.
# * `pProgressData`   application data to pass to the progress function.

# ### Returns
# `CE_None` on success or `CE_Failure` if the operation doesn't work.

# For example, to build overview level 2, 4 and 8 on all bands the following
# call could be made:

# ```C
#    int       anOverviewList[3] = { 2, 4, 8 };
#    poDataset->BuildOverviews( "NEAREST", 3, anOverviewList, 0, NULL, 
#                               GDALDummyProgress, NULL );
# ```
# """
# _buildoverviews(arg1::GDALDatasetH,
#                 pszResampling::Ptr{UInt8},
#                 nOverviews::Integer,
#                 panOverviewList::Ptr{Cint},
#                 nListBands::Integer,
#                 panBandList::Ptr{Cint},
#                 pfnProgress::GDALProgressFunc,
#                 pProgressData::Ptr{Void}) =
#     GDALBuildOverviews(pszResampling, nOverviews, panOverviewList, nListBands,
#                        panBandList, pfnProgress, pProgressData)::CPLErr

# function buildoverviews(hDS::GDALDatasetH,
#                         resampling::ASCIIString,
#                         overviewlist::Vector{Cint},
#                         bandList::Vector{Cint})
#     result = _buildoverviews(hDS, pointer(resampling),
#                              length(overviewlist),
#                              pointer(overviewlist),
#                              length(bandlist),
#                              pointer(bandlist),
#                              C_NULL, C_NULL)
#     (result == CE_Failure) && error("Failed to build overviews")
# end

# """
# Fetch all open GDAL dataset handles.

# NOTE: This method is not thread safe. The returned list may change at any time
# and it should not be freed.

# ### Parameters
# * `pnCount`     integer into which to place the count of dataset pointers being
# returned.

# ### Returns
# a pointer to an array of dataset handles.
# """
# opendatasets(hDS::Ptr{Ptr{GDALDatasetH}}, pnCount::Ptr{Cint}) = 
#     GDALGetOpenDatasets(hdS, pnCount)

# """
# Adds a mask band to the dataset.

# The default implementation of the `CreateMaskBand()` method is implemented
# based on similar rules to the .ovr handling implemented using the
# `GDALDefaultOverviews` object. A TIFF file with the extension .msk will be
# created with the same basename as the original file, and it will have one band.
# The mask images will be deflate compressed tiled images with the same block
# size as the original image if possible.

# If you got a mask band with a previous call to `GetMaskBand()`, it might be
# invalidated by CreateMaskBand(). So you have to call `GetMaskBand()` again.

# See also: http://trac.osgeo.org/gdal/wiki/rfc15_nodatabitmask

# ### Parameters
# * `nFlags`  ignored. `GMF_PER_DATASET` will be assumed.

# ### Returns
# `CE_None` on success or `CE_Failure` on an error.
# """
# _createdatasetmaskband(hDS::GDALDatasetH,
#                        nFlags::Integer = GMF_PER_DATASET) =
#     GDALCreateDatasetMaskBand(hDS, nFlags)::CPLErr

# function createdatasetmaskband(hDS::GDALDatasetH)
#     result = _createdatasetmaskband(hDS)
#     (result == CE_Failure) && error("Failed to create dataset mask band")
# end

# """
# Get output projection for GCPs.

# The projection string follows the normal rules from `GetProjectionRef()`.

# ### Returns
# internal projection string or `""` if there are no GCPs. It should not be
# altered, freed or expected to last for long.
# """
# _getgcpprojection(dataset::GDALDatasetH) =
#     GDALGetGCPProjection(dataset)::Ptr{UInt8}

# getgcpprojection(dataset::GDALDatasetH) =
#     bytestring(_getgcpprojection(dataset))

# """
# Fetch GCPs.

# ### Returns
# pointer to internal GCP structure list. It should not be modified, and may
# change on the next GDAL call.
# """
# _getgcps(dataset::GDALDatasetH) = GDALGetGCPs(dataset)::Ptr{GDAL_GCP}

# """
# Assign GCPs.

# This method assigns the passed set of GCPs to this dataset, as well as setting
# their coordinate system. Internally copies are made of the coordinate system
# and list of points, so the caller remains responsible for deallocating these
# arguments if appropriate.

# Most formats do not support setting of GCPs, even formats that can handle GCPs.
# These formats will return `CE_Failure`.

# ### Parameters
# * `nGCPCount`           number of GCPs being assigned.
# * `pasGCPList`          array of `nGCPCount` GCP structures to be assigned
# * `pszGCPProjection`    the new OGC WKT coordinate system to assign for the GCP
# output coordinates. Should be `""` if no output coordinate system is known.

# ### Returns
# `CE_None` on success, `CE_Failure` on failure (including if action is not
# supported for this format).
# """
# _setgcps(dataset::GDALDatasetH,
#          nGCPCount::Integer,
#          pasGCPList::Ptr{GDAL_GCP},
#          pszGCPProjection::Ptr{UInt8}) =
#     GDALSetGCPs(dataset, nGCPCount, pasGCPList, pszGCPProjection)::CPLErr