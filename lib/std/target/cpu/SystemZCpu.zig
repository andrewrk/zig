const feature = @import("std").target.feature;
const CpuInfo = @import("std").target.cpu.CpuInfo;

pub const SystemZCpu = enum {
    Arch10,
    Arch11,
    Arch12,
    Arch13,
    Arch8,
    Arch9,
    Generic,
    Z10,
    Z13,
    Z14,
    Z15,
    Z196,
    ZEC12,

    pub fn getInfo(self: @This()) CpuInfo {
        return cpu_infos[@enumToInt(self)];
    }

    pub const FeatureType = feature.SystemZFeature;

    const cpu_infos = [@memberCount(@This())]CpuInfo(@This()) {
        CpuInfo(@This()).create(.Arch10, "arch10", &[_]FeatureType {
            .DfpZonedConversion,
            .DistinctOps,
            .EnhancedDat2,
            .ExecutionHint,
            .FpExtension,
            .FastSerialization,
            .HighWord,
            .InterlockedAccess1,
            .LoadAndTrap,
            .LoadStoreOnCond,
            .MessageSecurityAssistExtension3,
            .MessageSecurityAssistExtension4,
            .MiscellaneousExtensions,
            .PopulationCount,
            .ProcessorAssist,
            .ResetReferenceBitsMultiple,
            .TransactionalExecution,
        },
        CpuInfo(@This()).create(.Arch11, "arch11", &[_]FeatureType {
            .DfpPackedConversion,
            .DfpZonedConversion,
            .DistinctOps,
            .EnhancedDat2,
            .ExecutionHint,
            .FpExtension,
            .FastSerialization,
            .HighWord,
            .InterlockedAccess1,
            .LoadAndTrap,
            .LoadAndZeroRightmostByte,
            .LoadStoreOnCond,
            .LoadStoreOnCond2,
            .MessageSecurityAssistExtension3,
            .MessageSecurityAssistExtension4,
            .MessageSecurityAssistExtension5,
            .MiscellaneousExtensions,
            .PopulationCount,
            .ProcessorAssist,
            .ResetReferenceBitsMultiple,
            .TransactionalExecution,
            .Vector,
        },
        CpuInfo(@This()).create(.Arch12, "arch12", &[_]FeatureType {
            .DfpPackedConversion,
            .DfpZonedConversion,
            .DistinctOps,
            .EnhancedDat2,
            .ExecutionHint,
            .FpExtension,
            .FastSerialization,
            .GuardedStorage,
            .HighWord,
            .InsertReferenceBitsMultiple,
            .InterlockedAccess1,
            .LoadAndTrap,
            .LoadAndZeroRightmostByte,
            .LoadStoreOnCond,
            .LoadStoreOnCond2,
            .MessageSecurityAssistExtension3,
            .MessageSecurityAssistExtension4,
            .MessageSecurityAssistExtension5,
            .MessageSecurityAssistExtension7,
            .MessageSecurityAssistExtension8,
            .MiscellaneousExtensions,
            .MiscellaneousExtensions2,
            .PopulationCount,
            .ProcessorAssist,
            .ResetReferenceBitsMultiple,
            .TransactionalExecution,
            .Vector,
            .VectorEnhancements1,
            .VectorPackedDecimal,
        },
        CpuInfo(@This()).create(.Arch13, "arch13", &[_]FeatureType {
            .DfpPackedConversion,
            .DfpZonedConversion,
            .DeflateConversion,
            .DistinctOps,
            .EnhancedDat2,
            .EnhancedSort,
            .ExecutionHint,
            .FpExtension,
            .FastSerialization,
            .GuardedStorage,
            .HighWord,
            .InsertReferenceBitsMultiple,
            .InterlockedAccess1,
            .LoadAndTrap,
            .LoadAndZeroRightmostByte,
            .LoadStoreOnCond,
            .LoadStoreOnCond2,
            .MessageSecurityAssistExtension3,
            .MessageSecurityAssistExtension4,
            .MessageSecurityAssistExtension5,
            .MessageSecurityAssistExtension7,
            .MessageSecurityAssistExtension8,
            .MessageSecurityAssistExtension9,
            .MiscellaneousExtensions,
            .MiscellaneousExtensions2,
            .MiscellaneousExtensions3,
            .PopulationCount,
            .ProcessorAssist,
            .ResetReferenceBitsMultiple,
            .TransactionalExecution,
            .Vector,
            .VectorEnhancements1,
            .VectorEnhancements2,
            .VectorPackedDecimal,
            .VectorPackedDecimalEnhancement,
        },
        CpuInfo(@This()).create(.Arch8, "arch8", &[_]FeatureType {
        },
        CpuInfo(@This()).create(.Arch9, "arch9", &[_]FeatureType {
            .DistinctOps,
            .FpExtension,
            .FastSerialization,
            .HighWord,
            .InterlockedAccess1,
            .LoadStoreOnCond,
            .MessageSecurityAssistExtension3,
            .MessageSecurityAssistExtension4,
            .PopulationCount,
            .ResetReferenceBitsMultiple,
        },
        CpuInfo(@This()).create(.Generic, "generic", &[_]FeatureType {
        },
        CpuInfo(@This()).create(.Z10, "z10", &[_]FeatureType {
        },
        CpuInfo(@This()).create(.Z13, "z13", &[_]FeatureType {
            .DfpPackedConversion,
            .DfpZonedConversion,
            .DistinctOps,
            .EnhancedDat2,
            .ExecutionHint,
            .FpExtension,
            .FastSerialization,
            .HighWord,
            .InterlockedAccess1,
            .LoadAndTrap,
            .LoadAndZeroRightmostByte,
            .LoadStoreOnCond,
            .LoadStoreOnCond2,
            .MessageSecurityAssistExtension3,
            .MessageSecurityAssistExtension4,
            .MessageSecurityAssistExtension5,
            .MiscellaneousExtensions,
            .PopulationCount,
            .ProcessorAssist,
            .ResetReferenceBitsMultiple,
            .TransactionalExecution,
            .Vector,
        },
        CpuInfo(@This()).create(.Z14, "z14", &[_]FeatureType {
            .DfpPackedConversion,
            .DfpZonedConversion,
            .DistinctOps,
            .EnhancedDat2,
            .ExecutionHint,
            .FpExtension,
            .FastSerialization,
            .GuardedStorage,
            .HighWord,
            .InsertReferenceBitsMultiple,
            .InterlockedAccess1,
            .LoadAndTrap,
            .LoadAndZeroRightmostByte,
            .LoadStoreOnCond,
            .LoadStoreOnCond2,
            .MessageSecurityAssistExtension3,
            .MessageSecurityAssistExtension4,
            .MessageSecurityAssistExtension5,
            .MessageSecurityAssistExtension7,
            .MessageSecurityAssistExtension8,
            .MiscellaneousExtensions,
            .MiscellaneousExtensions2,
            .PopulationCount,
            .ProcessorAssist,
            .ResetReferenceBitsMultiple,
            .TransactionalExecution,
            .Vector,
            .VectorEnhancements1,
            .VectorPackedDecimal,
        },
        CpuInfo(@This()).create(.Z15, "z15", &[_]FeatureType {
            .DfpPackedConversion,
            .DfpZonedConversion,
            .DeflateConversion,
            .DistinctOps,
            .EnhancedDat2,
            .EnhancedSort,
            .ExecutionHint,
            .FpExtension,
            .FastSerialization,
            .GuardedStorage,
            .HighWord,
            .InsertReferenceBitsMultiple,
            .InterlockedAccess1,
            .LoadAndTrap,
            .LoadAndZeroRightmostByte,
            .LoadStoreOnCond,
            .LoadStoreOnCond2,
            .MessageSecurityAssistExtension3,
            .MessageSecurityAssistExtension4,
            .MessageSecurityAssistExtension5,
            .MessageSecurityAssistExtension7,
            .MessageSecurityAssistExtension8,
            .MessageSecurityAssistExtension9,
            .MiscellaneousExtensions,
            .MiscellaneousExtensions2,
            .MiscellaneousExtensions3,
            .PopulationCount,
            .ProcessorAssist,
            .ResetReferenceBitsMultiple,
            .TransactionalExecution,
            .Vector,
            .VectorEnhancements1,
            .VectorEnhancements2,
            .VectorPackedDecimal,
            .VectorPackedDecimalEnhancement,
        },
        CpuInfo(@This()).create(.Z196, "z196", &[_]FeatureType {
            .DistinctOps,
            .FpExtension,
            .FastSerialization,
            .HighWord,
            .InterlockedAccess1,
            .LoadStoreOnCond,
            .MessageSecurityAssistExtension3,
            .MessageSecurityAssistExtension4,
            .PopulationCount,
            .ResetReferenceBitsMultiple,
        },
        CpuInfo(@This()).create(.ZEC12, "zEC12", &[_]FeatureType {
            .DfpZonedConversion,
            .DistinctOps,
            .EnhancedDat2,
            .ExecutionHint,
            .FpExtension,
            .FastSerialization,
            .HighWord,
            .InterlockedAccess1,
            .LoadAndTrap,
            .LoadStoreOnCond,
            .MessageSecurityAssistExtension3,
            .MessageSecurityAssistExtension4,
            .MiscellaneousExtensions,
            .PopulationCount,
            .ProcessorAssist,
            .ResetReferenceBitsMultiple,
            .TransactionalExecution,
        },
    };
};
