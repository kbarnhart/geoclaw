r"""
xarray backends module: $CLAW/geoclaw/src/python/geoclaw/xarray_backends.py

Xarray backends for GeoClaw fixed grids and fgmax grids.

These only work for point_style = 2 (uniform regular)

The expectation is that you run commands that use these backends from the same
directory you run "make output".

Includes:

- class FGMaxBackend: Xarray backend for fgmax grids.
- class FGOutBackend: Xarray backend for fgout grids.

Usage:

.. code-block:: python
    import xarray as xr
    from clawpack.geoclaw.xarray_backends import FGOutBackend, FGMaxBackend

    # An example of a fgout grid.

    filename = '_output/fgout0001.b0001
    # provide the .bxxx file if binary format is used or the
    # .qxxx file if ascii format is used.
    # the format, fg number, and frame number are inferred from the filename.

    ds = xr.open_dataset(filename, engine=FGOutBackend, backend_kwargs={'epsg':epsg_code})
    # ds is now an xarray object. It can be interacted with directly or written to netcdf using
    ds.write_netcdf('filename.nc')

    # Optionally, provide an epsg code to assign the associated coordinate system to the file.
    # default behavior assigns no coordinate system.

    # An example of a fgmax grid.
    filename = "_output/fgmax0001.txt"
    ds = xr.open_dataset(filename, engine=FGMaxBackend, backend_kwargs={'epsg':epsg_code})


Dimensions:

Files opened with FGOutBackend will have dimensions time, y, x.
Files opened with FGMaxBackend will have dimensions y, x.

Variable naming:

For fixed grid geoclaw files, the dataset will have the following variables:
- h
- hu
- hv
- eta

Fixed grid dclaw files will have
- h
- hu
- hv
- hm
- pb
- hchi
- delta_a
- eta

Depending on the number of variables specified in the setrun.py fgmax files will
have a portion of the following variables:

If rundata.fgmax_data.num_fgmax_val == 1

- arrival_time, Wave arrival time (based on eta>sea_level + fg.arrival_tol)
- h_max, Maximum water depth
- eta_max, Maximum water surface elevation
- h_max_time, Time of maximum water depth

If rundata.fgmax_data.num_fgmax_val == 2:

- s_max, Maximum velocity
- s_max_time, Time of maximum velocity

If rundata.fgmax_data.num_fgmax_val == 5:

- hs_max, Maximum momentum
- hs_max_time, Time of maximum momentum
- hss_max, Maximum momentum flux
- hss_max_time, Time of maximum momentum flux
- h_min, Minimum depth
- h_min_time, Time of minimum depth


See the following links for additional information about xarray Backends.

- https://docs.xarray.dev/en/stable/generated/xarray.backends.BackendEntrypoint.html#xarray.backends.BackendEntrypoint
- import https://docs.xarray.dev/en/stable/generated/xarray.open_dataset.html
"""

import os

import numpy as np
import rioxarray  # activate the rio accessor
import xarray as xr
from clawpack.geoclaw import fgmax_tools, fgout_tools
from xarray.backends import BackendEntrypoint

_qelements_dclaw = ["h", "hu", "hv", "hm", "pb", "hchi", "delta_a", "eta"]
_qelements_geoclaw = ["h", "hu", "hv", "eta"]

_qunits = {
    "h": "meters",
    "hu": "meters squared per second",
    "hv": "meters squared per second",
    "hm": "meters",
    "pb": "newton per meter squared",
    "hchi": "meters",
    "delta_a": "meters",
    "eta": "meters",
}

time_unit = "seconds"
reference_time = "model start"
space_unit = "meters"
nodata = np.nan


def _prepare_var(data, mask, dims, units, nodata, long_name):
    "Reorient array into the format xarray expects and generate the mapping."
    data[mask] = nodata
    data = data.T
    data = np.flipud(data)
    mapping = (
        dims,
        data,
        {"units": units, "_FillValue": nodata, "long_name": long_name},
    )
    return mapping


class FGOutBackend(BackendEntrypoint):
    "Xarray Backend for Clawpack fixed grid format."

    def open_dataset(
        self,
        filename,  # path to fgout file.
        epsg=None,  # epsg code
        drop_variables=None,  # name of any elements of q to drop.
    ):

        if drop_variables is None:
            drop_variables = []

        full_path = os.path.abspath(filename)
        filename = os.path.basename(full_path)
        outdir = os.path.basename(os.path.dirname(full_path))

        # filename has the format fgoutXXXX.qYYYY (ascii)
        # or fgoutXXXX.bYYYY (binary)
        # where XXXX is the fixed grid number and YYYY is the frame
        # number.
        type_code = filename.split(".")[-1][0]
        fgno = int(filename.split(".")[0][-4:])
        frameno = int(filename.split(".")[-1][-4:])
        if type_code == "q":  # TODO, is this correct?
            output_format = "ascii"
        elif type_code == "b":
            output_format = "binary32"  # format of fgout grid output
        else:
            raise ValueError("Invalid FGout output format. Must be ascii or binary.")

        fgout_grid = fgout_tools.FGoutGrid(fgno, outdir, output_format)

        if fgout_grid.point_style != 2:
            raise ValueError("FGOutBackend only works with fg.point_style=2")

        fgout_grid.read_fgout_grids_data()
        fgout = fgout_grid.read_frame(frameno)

        time = fgout.t
        # both come in ascending. flip to give expected order.
        x = fgout.x
        y = np.flipud(fgout.y)
        nj = len(x)
        ni = len(y)

        # mask based on dry tolerance
        mask = fgout.q[0, :, :] < 0.001

        # determine if geoclaw or dclaw
        nvars = fgout.q.shape[0]
        if nvars == 8:
            _qelements = _qelements_dclaw
        else:
            _qelements = _qelements_geoclaw

        # create data_vars dictionary
        data_vars = {}
        for i in range(nvars):
            Q = fgout.q[i, :, :]
            # mask all but eta based on h presence.
            if i < 7:
                Q[mask] = nodata

            # to keep xarray happy, need to transpose and flip ud.
            Q = Q.T
            Q = np.flipud(Q)
            Q = Q.reshape((1, ni, nj))  # reshape to add a time dimension.

            # construct variable
            varname = _qelements[i]

            data_array_attrs = {"units": _qunits[varname], "_FillValue": nodata}

            if varname not in drop_variables:
                data_vars[varname] = (
                    [
                        "time",
                        "y",
                        "x",
                    ],
                    Q,
                    data_array_attrs,
                )

        ds_attrs = {"description": "Clawpack model output"}

        ds = xr.Dataset(
            data_vars=data_vars,
            coords=dict(
                x=(["x"], x, {"units": space_unit}),
                y=(["y"], y, {"units": space_unit}),
                time=("time", [time], {"units": "seconds"}),
                reference_time=reference_time,
            ),
            attrs=ds_attrs,
        )

        if epsg is not None:
            ds.rio.write_crs(
                epsg,
                inplace=True,
            ).rio.set_spatial_dims(
                x_dim="x",
                y_dim="y",
                inplace=True,
            ).rio.write_coordinate_system(inplace=True)
            # https://corteva.github.io/rioxarray/stable/getting_started/crs_management.html#Spatial-dimensions
            # https://gis.stackexchange.com/questions/470207/how-to-write-crs-info-to-netcdf-in-a-way-qgis-can-read-python-xarray

        return ds

    open_dataset_parameters = ["filename", "drop_variables"]

    description = "Use Clawpack fixed grid output files in Xarray"
    url = "https://www.clawpack.org/fgout.html"


class FGMaxBackend(BackendEntrypoint):
    "Xarray Backend for Clawpack fgmax grid format."

    def open_dataset(
        self,
        filename,
        epsg=None,
        drop_variables=None,
    ):

        if drop_variables is None:
            drop_variables = []

        # expectation is that you are in a run directory with a file 'fgmax_grids.data' in it.
        fgno = int(os.path.basename(filename).split(".")[0][-4:])

        fg = fgmax_tools.FGmaxGrid()
        fg.read_fgmax_grids_data(fgno=fgno)
        if fg.point_style != 2:
            raise ValueError("FGMaxBackend only works with fg.point_style=2")

        fg.read_output()

        # Construct the x and y coordinates
        # Both come in ascending, therefore flip y so that it is ordered as expected.
        x = fg.x
        y = np.flipud(fg.y)

        # Construct the data_vars array. To organize the
        # data in the way expected by netcdf standards, need
        # to both transpose and flipud the array.

        data_vars = {}

        data_vars["arrival_time"] = _prepare_var(
            fg.arrival_time.data,
            fg.arrival_time.mask,
            [
                "y",
                "x",
            ],
            "seconds",
            nodata,
            "Wave arrival time",
        )

        data_vars["h_max"] = _prepare_var(
            fg.h.data,
            fg.h.mask,
            [
                "y",
                "x",
            ],
            "meters",
            nodata,
            "Maximum water depth",
        )

        data_vars["eta_max"] = _prepare_var(
            fg.h.data + fg.B.data,
            fg.h.mask,
            [
                "y",
                "x",
            ],
            "meters",
            nodata,
            "Maximum water surface elevation",
        )

        data_vars["h_max_time"] = _prepare_var(
            fg.h_time.data,
            fg.h_time.mask,
            [
                "y",
                "x",
            ],
            "seconds",
            nodata,
            "Time of maximum water depth",
        )

        if hasattr(fg, "s"):
            if hasattr(fg.s, "data"):
                data_vars["s_max"] = _prepare_var(
                    fg.s.data,
                    fg.s.mask,
                    [
                        "y",
                        "x",
                    ],
                    "meters per second",
                    nodata,
                    "Maximum velocity",
                )
                data_vars["s_max_time"] = _prepare_var(
                    fg.s_time.data,
                    fg.s_time.mask,
                    [
                        "y",
                        "x",
                    ],
                    "seconds",
                    nodata,
                    "Time of maximum velocity",
                )
        if hasattr(fg, "hs"):
            if hasattr(fg.hs, "data"):
                data_vars["hs_max"] = _prepare_var(
                    fg.hs.data,
                    fg.hs.mask,
                    [
                        "y",
                        "x",
                    ],
                    "meters squared per second",
                    nodata,
                    "Maximum momentum",
                )
                data_vars["hs_max_time"] = _prepare_var(
                    fg.hs_time.data,
                    fg.hs_time.mask,
                    [
                        "y",
                        "x",
                    ],
                    "seconds",
                    nodata,
                    "Time of maximum momentum",
                )

                data_vars["hss_max"] = _prepare_var(
                    fg.hss.data,
                    fg.hss.mask,
                    [
                        "y",
                        "x",
                    ],
                    "meters cubed per second squared",
                    nodata,
                    "Maximum momentum flux",
                )
                data_vars["hss_max_time"] = _prepare_var(
                    fg.hss_time.data,
                    fg.hss_time.mask,
                    [
                        "y",
                        "x",
                    ],
                    "seconds",
                    nodata,
                    "Time of maximum momentum flux",
                )

                data_vars["h_min"] = _prepare_var(
                    fg.hmin.data,
                    fg.hmin.mask,
                    [
                        "y",
                        "x",
                    ],
                    "meters",
                    nodata,
                    "Minimum depth",
                )
                data_vars["h_min_time"] = _prepare_var(
                    fg.hmin_time.data,
                    fg.hmin_time.mask,
                    [
                        "y",
                        "x",
                    ],
                    "seconds",
                    nodata,
                    "Time of minimum depth",
                )

        # drop requested variables
        for var in drop_variables:
            if var in data_vars.keys():
                del data_vars[var]

        # Construct the values from
        ds_attrs = {"description": "D-Claw model output"}

        ds = xr.Dataset(
            data_vars=data_vars,
            coords=dict(
                x=(["x"], x, {"units": "meters"}),
                y=(["y"], y, {"units": "meters"}),
            ),
            attrs=ds_attrs,
        )

        if epsg is not None:

            ds.rio.write_crs(
                epsg,
                inplace=True,
            ).rio.set_spatial_dims(
                x_dim="x",
                y_dim="y",
                inplace=True,
            ).rio.write_coordinate_system(inplace=True)
            # https://corteva.github.io/rioxarray/stable/getting_started/crs_management.html#Spatial-dimensions
            # https://gis.stackexchange.com/questions/470207/how-to-write-crs-info-to-netcdf-in-a-way-qgis-can-read-python-xarray

        return ds

    open_dataset_parameters = ["filename", "drop_variables"]

    description = "Use Clawpack fix grid monitoring files in Xarray"
    url = "https://www.clawpack.org/fgmax.html#fgmax"