const feature = @import("std").target.feature;
const CpuInfo = @import("std").target.cpu.CpuInfo;

pub const SparcCpu = enum {
    At697e,
    At697f,
    F934,
    Generic,
    Gr712rc,
    Gr740,
    Hypersparc,
    Leon2,
    Leon3,
    Leon4,
    Ma2080,
    Ma2085,
    Ma2100,
    Ma2150,
    Ma2155,
    Ma2450,
    Ma2455,
    Ma2480,
    Ma2485,
    Ma2x5x,
    Ma2x8x,
    Myriad2,
    Myriad21,
    Myriad22,
    Myriad23,
    Niagara,
    Niagara2,
    Niagara3,
    Niagara4,
    Sparclet,
    Sparclite,
    Sparclite86x,
    Supersparc,
    Tsc701,
    Ultrasparc,
    Ultrasparc3,
    Ut699,
    V7,
    V8,
    V9,

    const FeatureType = feature.SparcFeature;

    pub fn getInfo(self: @This()) CpuInfo(@This(), FeatureType) {
        return cpu_infos[@enumToInt(self)];
    }

    pub const cpu_infos = [@memberCount(@This())]CpuInfo(@This(), FeatureType) {
        CpuInfo(@This(), FeatureType).create(.At697e, "at697e", &[_]FeatureType {
            .Leon,
            .Insertnopload,
        }),
        CpuInfo(@This(), FeatureType).create(.At697f, "at697f", &[_]FeatureType {
            .Leon,
            .Insertnopload,
        }),
        CpuInfo(@This(), FeatureType).create(.F934, "f934", &[_]FeatureType {
        }),
        CpuInfo(@This(), FeatureType).create(.Generic, "generic", &[_]FeatureType {
        }),
        CpuInfo(@This(), FeatureType).create(.Gr712rc, "gr712rc", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Gr740, "gr740", &[_]FeatureType {
            .Leon,
            .Leonpwrpsr,
            .Hasleoncasa,
            .Leoncyclecounter,
            .Hasumacsmac,
        }),
        CpuInfo(@This(), FeatureType).create(.Hypersparc, "hypersparc", &[_]FeatureType {
        }),
        CpuInfo(@This(), FeatureType).create(.Leon2, "leon2", &[_]FeatureType {
            .Leon,
        }),
        CpuInfo(@This(), FeatureType).create(.Leon3, "leon3", &[_]FeatureType {
            .Leon,
            .Hasumacsmac,
        }),
        CpuInfo(@This(), FeatureType).create(.Leon4, "leon4", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
            .Hasumacsmac,
        }),
        CpuInfo(@This(), FeatureType).create(.Ma2080, "ma2080", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Ma2085, "ma2085", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Ma2100, "ma2100", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Ma2150, "ma2150", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Ma2155, "ma2155", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Ma2450, "ma2450", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Ma2455, "ma2455", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Ma2480, "ma2480", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Ma2485, "ma2485", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Ma2x5x, "ma2x5x", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Ma2x8x, "ma2x8x", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Myriad2, "myriad2", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Myriad21, "myriad2.1", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Myriad22, "myriad2.2", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Myriad23, "myriad2.3", &[_]FeatureType {
            .Leon,
            .Hasleoncasa,
        }),
        CpuInfo(@This(), FeatureType).create(.Niagara, "niagara", &[_]FeatureType {
            .DeprecatedV8,
            .V9,
            .Vis,
            .Vis2,
        }),
        CpuInfo(@This(), FeatureType).create(.Niagara2, "niagara2", &[_]FeatureType {
            .DeprecatedV8,
            .V9,
            .Vis,
            .Vis2,
            .Popc,
        }),
        CpuInfo(@This(), FeatureType).create(.Niagara3, "niagara3", &[_]FeatureType {
            .DeprecatedV8,
            .V9,
            .Vis,
            .Vis2,
            .Popc,
        }),
        CpuInfo(@This(), FeatureType).create(.Niagara4, "niagara4", &[_]FeatureType {
            .DeprecatedV8,
            .V9,
            .Vis,
            .Vis2,
            .Vis3,
            .Popc,
        }),
        CpuInfo(@This(), FeatureType).create(.Sparclet, "sparclet", &[_]FeatureType {
        }),
        CpuInfo(@This(), FeatureType).create(.Sparclite, "sparclite", &[_]FeatureType {
        }),
        CpuInfo(@This(), FeatureType).create(.Sparclite86x, "sparclite86x", &[_]FeatureType {
        }),
        CpuInfo(@This(), FeatureType).create(.Supersparc, "supersparc", &[_]FeatureType {
        }),
        CpuInfo(@This(), FeatureType).create(.Tsc701, "tsc701", &[_]FeatureType {
        }),
        CpuInfo(@This(), FeatureType).create(.Ultrasparc, "ultrasparc", &[_]FeatureType {
            .DeprecatedV8,
            .V9,
            .Vis,
        }),
        CpuInfo(@This(), FeatureType).create(.Ultrasparc3, "ultrasparc3", &[_]FeatureType {
            .DeprecatedV8,
            .V9,
            .Vis,
            .Vis2,
        }),
        CpuInfo(@This(), FeatureType).create(.Ut699, "ut699", &[_]FeatureType {
            .Leon,
            .NoFmuls,
            .NoFsmuld,
            .Fixallfdivsqrt,
            .Insertnopload,
        }),
        CpuInfo(@This(), FeatureType).create(.V7, "v7", &[_]FeatureType {
            .NoFsmuld,
            .SoftMulDiv,
        }),
        CpuInfo(@This(), FeatureType).create(.V8, "v8", &[_]FeatureType {
        }),
        CpuInfo(@This(), FeatureType).create(.V9, "v9", &[_]FeatureType {
            .V9,
        }),
    };
};
