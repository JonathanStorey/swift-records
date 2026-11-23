import Foundation
import Versioning
#if canImport(CoreLocation)
import CoreLocation
#endif

/// A location as CloudKit stores it, with every value a `CLLocation` saves
/// to a record.
///
/// ```swift
/// struct Place: Codable {
///     var home: Location?
///     var route: [Location] = []
/// }
///
/// place.home?.latitude             // 41.88
/// place.home?.clLocation           // CLLocation, on Apple platforms
/// ```
///
/// It is a plain value, so optional locations and lists of locations work
/// like any other property. It is `Codable` by synthesis, so JSON holds
/// every value and a record encoder can recognize a location by its type.
/// CoreLocation exists only on Apple platforms, so on Linux a `Location` has
/// no `clLocation`.
///
/// Values a location did not measure use CoreLocation's conventions: a
/// negative accuracy, course or speed means the value is invalid.
public struct Location: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Meters above sea level.
    public var altitude: Double
    /// Meters. Negative when the coordinate is invalid.
    public var horizontalAccuracy: Double
    /// Meters. Negative when the altitude is invalid.
    public var verticalAccuracy: Double
    /// Degrees from true north. Negative when invalid.
    public var course: Double
    /// Degrees. Negative when the course is invalid.
    public var courseAccuracy: Double
    /// Meters per second. Negative when invalid.
    public var speed: Double
    /// Meters per second. Negative when the speed is invalid.
    public var speedAccuracy: Double
    /// When the location was measured.
    public var timestamp: Date

    /// A location with the defaults `CLLocation(latitude:longitude:)` uses
    /// for anything not given.
    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double = 0,
        horizontalAccuracy: Double = 0,
        verticalAccuracy: Double = -1,
        course: Double = -1,
        courseAccuracy: Double = -1,
        speed: Double = -1,
        speedAccuracy: Double = -1,
        timestamp: Date = Date()
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.timestamp = timestamp
    }
}

extension Location: Mergeable {
    /// The side that changed the location, or the later measurement by
    /// `timestamp` when both did. Two different measurements from the same
    /// moment conflict.
    public func merging(with theirs: Location, from base: Location) throws(MergeConflict) -> Location {
        if theirs == base { return self }
        if self == base { return theirs }
        return try merging(with: theirs)
    }

    /// The later measurement by `timestamp`.
    public func merging(with theirs: Location) throws(MergeConflict) -> Location {
        if self == theirs { return self }
        guard timestamp != theirs.timestamp else { throw MergeConflict() }
        return timestamp > theirs.timestamp ? self : theirs
    }
}

#if canImport(CoreLocation)
extension Location {
    /// The location as a `CLLocation`, for CoreLocation and MapKit.
    public var clLocation: CLLocation {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocation(coordinate: coordinate, altitude: altitude, horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy, course: course, courseAccuracy: courseAccuracy, speed: speed, speedAccuracy: speedAccuracy, timestamp: timestamp)
    }

    /// The values of a `CLLocation`.
    public init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            course: location.course,
            courseAccuracy: location.courseAccuracy,
            speed: location.speed,
            speedAccuracy: location.speedAccuracy,
            timestamp: location.timestamp
        )
    }
}
#endif
