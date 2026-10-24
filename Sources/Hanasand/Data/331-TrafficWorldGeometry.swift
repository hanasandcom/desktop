import CoreGraphics
import Foundation

struct TrafficWorldRing: Equatable {
    let coordinates: [TrafficMapCoordinate]
}

enum TrafficWorldGeometryError: Error {
    case invalidFeatureCollection
    case invalidFeature
    case invalidRing
}

enum TrafficWorldGeometry {
    static let features: [[TrafficWorldRing]] = {
        guard let url = Bundle.module.url(forResource: "traffic-world", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let features = try? decode(data) else { return [] }
        return features
    }()

    static func decode(_ data: Data) throws -> [[TrafficWorldRing]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "FeatureCollection",
              let rawFeatures = root["features"] as? [[String: Any]] else {
            throw TrafficWorldGeometryError.invalidFeatureCollection
        }

        return try rawFeatures.map { feature in
            guard let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String,
                  let coordinates = geometry["coordinates"] else {
                throw TrafficWorldGeometryError.invalidFeature
            }
            switch type {
            case "Polygon":
                guard let rings = coordinates as? [[[Any]]] else { throw TrafficWorldGeometryError.invalidFeature }
                return try rings.map(decodeRing)
            case "MultiPolygon":
                guard let polygons = coordinates as? [[[[Any]]]] else { throw TrafficWorldGeometryError.invalidFeature }
                return try polygons.flatMap { try $0.map(decodeRing) }
            default:
                throw TrafficWorldGeometryError.invalidFeature
            }
        }
    }

    static func projectedPoint(_ coordinate: TrafficMapCoordinate, size: CGSize) -> CGPoint {
        CGPoint(
            x: (coordinate.longitude + 180) / 360 * size.width,
            y: (90 - coordinate.latitude) / 180 * size.height
        )
    }

    static func displayedPoint(_ coordinate: TrafficMapCoordinate, size: CGSize, zoom: CGFloat, offset: CGSize) -> CGPoint {
        let point = projectedPoint(coordinate, size: size)
        return CGPoint(
            x: (point.x - size.width / 2) * zoom + size.width / 2 + offset.width,
            y: (point.y - size.height / 2) * zoom + size.height / 2 + offset.height
        )
    }

    private static func decodeRing(_ rawCoordinates: [[Any]]) throws -> TrafficWorldRing {
        let coordinates = try rawCoordinates.map { raw -> TrafficMapCoordinate in
            guard raw.count >= 2,
                  let longitude = (raw[0] as? NSNumber)?.doubleValue,
                  let latitude = (raw[1] as? NSNumber)?.doubleValue,
                  longitude.isFinite, (-180...180).contains(longitude),
                  latitude.isFinite, (-90...90).contains(latitude) else {
                throw TrafficWorldGeometryError.invalidRing
            }
            return TrafficMapCoordinate(latitude: latitude, longitude: longitude)
        }
        guard coordinates.count >= 4, coordinates.first == coordinates.last else {
            throw TrafficWorldGeometryError.invalidRing
        }
        return TrafficWorldRing(coordinates: coordinates)
    }
}
