public struct MemoryPageCounts: Sendable, Equatable {
    public let internalPages: Int64
    public let purgeablePages: Int64
    public let externalPages: Int64
    public let wiredPages: Int64
    public let compressorPages: Int64

    public init(
        internalPages: Int64,
        purgeablePages: Int64,
        externalPages: Int64,
        wiredPages: Int64,
        compressorPages: Int64
    ) {
        self.internalPages = internalPages
        self.purgeablePages = purgeablePages
        self.externalPages = externalPages
        self.wiredPages = wiredPages
        self.compressorPages = compressorPages
    }
}

public struct MemoryBreakdown: Sendable, Equatable {
    public let applicationBytes: Int64
    public let wiredBytes: Int64
    public let compressedBytes: Int64
    public let cachedBytes: Int64
    public let usedBytes: Int64
    public let availableBytes: Int64

    public static func calculate(
        totalBytes: Int64,
        pageSize: Int64,
        pages: MemoryPageCounts
    ) -> Self {
        let applicationPages = max(0, pages.internalPages - pages.purgeablePages)
        let cachedPages = pages.externalPages + pages.purgeablePages
        let applicationBytes = applicationPages * pageSize
        let wiredBytes = pages.wiredPages * pageSize
        let compressedBytes = pages.compressorPages * pageSize
        let cachedBytes = cachedPages * pageSize
        let usedBytes = applicationBytes + wiredBytes + compressedBytes

        return Self(
            applicationBytes: applicationBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedBytes: cachedBytes,
            usedBytes: usedBytes,
            availableBytes: max(0, totalBytes - usedBytes)
        )
    }
}

public enum MemoryPressureIndex {
    public static func score(
        kernelAvailableLevel: Int?,
        pressureState: Int,
        availableFraction: Double,
        compressedFraction: Double,
        swapFraction: Double
    ) -> Double {
        let clamp: (Double) -> Double = { min(1, max(0, $0)) }
        let kernel = kernelAvailableLevel.map { 1 - clamp(Double($0) / 100) } ?? 0
        let stateFloor: Double = pressureState == 4 ? 0.85 : (pressureState == 2 ? 0.60 : 0)
        let availability = clamp((0.20 - availableFraction) / 0.20) * 0.55
        let compression = clamp(compressedFraction / 0.35) * 0.25
        let swap = clamp(swapFraction) * 0.20
        return clamp(max(kernel, stateFloor, availability + compression + swap))
    }
}
