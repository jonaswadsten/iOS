//
//  HAAPI.swift
//  HomeAssistant
//
//  Created by Robbie Trencheny on 3/25/16.
//  Copyright © 2016 Robbie Trencheny. All rights reserved.
//

import Foundation
import Alamofire
import PromiseKit
import SwiftyJSON
import IKEventSource
import SwiftLocation
import CoreLocation
import Whisper
import AlamofireObjectMapper
import ObjectMapper

let prefs = NSUserDefaults.standardUserDefaults()

class HomeAssistantAPI: NSObject {
    
    let manager:Alamofire.Manager?
    
    var baseAPIURL : String = ""
    var apiPassword : String = ""
    
    var mostRecentlySentMessage : String = String()
    
    var services = [NSNetService]()
    
    init(baseAPIUrl: String, APIPassword: String) {
        baseAPIURL = baseAPIUrl+"/api/"
        apiPassword = APIPassword
        var defaultHeaders = Alamofire.Manager.sharedInstance.session.configuration.HTTPAdditionalHeaders ?? [:]
        if apiPassword != "" {
            defaultHeaders["X-HA-Access"] = apiPassword
        }
        
        let configuration = NSURLSessionConfiguration.defaultSessionConfiguration()
        configuration.HTTPAdditionalHeaders = defaultHeaders
        
        self.manager = Alamofire.Manager(configuration: configuration)
        
        var sseHeaders : [String:String] = [:]
        
        if apiPassword != "" {
            sseHeaders["X-HA-Access"] = apiPassword
        }
        
        let eventSource: EventSource = EventSource(url: baseAPIURL+"stream", headers: sseHeaders)
        
        eventSource.onOpen {
            print("SSE: Connection Opened")
            Whistle(Murmur(title: "Connected to HA realtime API!"))
        }
        
        eventSource.onError { (error) in
            if let localizedDescription = error?.localizedDescription {
                Whistle(Murmur(title: "SSE Error! \(localizedDescription)"))
            }
            print("SSE: Error", error)
        }
        
        eventSource.onMessage { (id, eventName, data) in
            if let event = Mapper<SSEEvent>().map(data) {
                NSNotificationCenter.defaultCenter().postNotificationName("sse."+event.Type, object: nil, userInfo: event.toJSON())
            } else {
                print("Unable to ObjectMap this SSE message", eventName, data)
            }
        }
    }
    
    func submitLocation(updateType: String, deviceId: String, latitude: Double, longitude: Double, accuracy: Double, locationName: String) {
        UIDevice.currentDevice().batteryMonitoringEnabled = true
        
        var locationUpdate : [String:AnyObject] = [
            "battery": Int(UIDevice.currentDevice().batteryLevel*100),
            "gps": [latitude, longitude],
            "gps_accuracy": accuracy,
            "hostname": UIDevice().name,
            "dev_id": deviceId
        ]
        
        if locationName != "" {
           locationUpdate["location_name"] = locationName
        }
        
        self.CallService("device_tracker", service: "see", serviceData: locationUpdate).then {_ in
            print("Device seen!")
        }
        
        UIDevice.currentDevice().batteryMonitoringEnabled = false
        
        let notification = UILocalNotification()
        notification.alertBody = updateType+", alerting Home Assistant"
        notification.alertAction = "open"
        notification.fireDate = NSDate()
        notification.soundName = UILocalNotificationDefaultSoundName
        UIApplication.sharedApplication().scheduleLocalNotification(notification)
    }
    
    func trackLocation(deviceId: String) {
        do {
            try SwiftLocation.shared.significantLocation({ (location) -> Void in
                self.submitLocation("Significant location change detected", deviceId: deviceId, latitude: location!.coordinate.latitude, longitude: location!.coordinate.longitude, accuracy: location!.horizontalAccuracy, locationName: "")
            }, onFail: { (error) -> Void in
                // something went wrong. request will be cancelled automatically
                print("Something went wrong when trying to get significant location updates! Error was:", error)
            })
        } catch {
            print("Error when trying to get sig location changes!!")
        }

        let regionCoordinates = CLLocationCoordinate2DMake(prefs.doubleForKey("latitude"), prefs.doubleForKey("longitude"))
        let region = CLCircularRegion(center: regionCoordinates, radius: CLLocationDistance(1000), identifier: "home_location")
        do {
            try SwiftLocation.shared.monitorRegion(region, onEnter: { (region) -> Void in
                print("Region entered!", region)
                self.submitLocation("Region entered", deviceId: deviceId, latitude: regionCoordinates.latitude, longitude: regionCoordinates.longitude, accuracy: 5000, locationName: "home")
            }) { (region) -> Void in
                print("Region exited!", region)
                self.submitLocation("Region exited", deviceId: deviceId, latitude: regionCoordinates.latitude, longitude: regionCoordinates.longitude, accuracy: 5000, locationName: "not_home")
            }
        } catch {
            print("Error when setting up home region location monitoring")
        }

    }
    
    func sendOneshotLocation() -> Promise<Bool> {
        return Promise { fulfill, reject in
            if let deviceId = prefs.stringForKey("deviceId") {
                do {
                    try SwiftLocation.shared.currentLocation(Accuracy.Neighborhood, timeout: 20, onSuccess: { (location) -> Void in
                        self.submitLocation("One off location update requested", deviceId: deviceId, latitude: location!.coordinate.latitude, longitude: location!.coordinate.longitude, accuracy: location!.horizontalAccuracy, locationName: "")
                        fulfill(true)
                    }) { (error) -> Void in
                        print("Error when trying to get a oneshot location!", error)
                        reject(error!)
                    }
                } catch {
                    print("Error when getting a oneshot location!")
                }
            }
        }
    }
    
    func GET(url:String) -> Promise<JSON> {
        let queryUrl = baseAPIURL+url
        return Promise { fulfill, reject in
            self.manager!.request(.GET, queryUrl).responseJSON { response in
                switch response.result {
                    case .Success:
                        if let value = response.result.value {
                            fulfill(JSON(value))
                        } else {
                            print("Response was not JSON!", response)
                        }
                    case .Failure(let error):
                        print("Error on GET request to \(url):", error)
                        reject(error)
                }
            }
        }
    }
    
    func POST(url:String, parameters: [String: AnyObject]) -> Promise<JSON> {
        mostRecentlySentMessage = url
        let queryUrl = baseAPIURL+url
        return Promise { fulfill, reject in
            self.manager!.request(.POST, queryUrl, parameters: parameters, encoding: .JSON).responseJSON { response in
                switch response.result {
                case .Success:
                    if let value = response.result.value {
                        fulfill(JSON(value))
                    } else {
                        print("Response was not JSON!", response)
                    }
                case .Failure(let error):
                    print("Error on GET request to \(url):", error)
                    reject(error)
                }
            }
        }
    }
    
    func GetStatus() -> Promise<StatusResponse> {
        let queryUrl = baseAPIURL+"config"
        return Promise { fulfill, reject in
            self.manager!.request(.GET, queryUrl).responseObject { (response: Response<StatusResponse, NSError>) in
                switch response.result {
                case .Success:
                    fulfill(response.result.value!)
                case .Failure(let error):
                    print("Error on GET request:", error)
                    reject(error)
                }
            }
        }
    }
    
    func GetConfig() -> Promise<ConfigResponse> {
        let queryUrl = baseAPIURL+"config"
        return Promise { fulfill, reject in
            self.manager!.request(.GET, queryUrl).responseObject { (response: Response<ConfigResponse, NSError>) in
                switch response.result {
                case .Success:
                    fulfill(response.result.value!)
                case .Failure(let error):
                    print("Error on GET request:", error)
                    reject(error)
                }
            }
        }
    }
    
    func GetBootstrap() -> Promise<JSON> {
        return GET("bootstrap")
    }
    
    func GetEvents() -> Promise<JSON> {
        return GET("events")
    }
    
    func GetServices() -> Promise<[ServicesResponse]> {
        let queryUrl = baseAPIURL+"services"
        return Promise { fulfill, reject in
            self.manager!.request(.GET, queryUrl).responseArray { (response: Response<[ServicesResponse], NSError>) in
                switch response.result {
                case .Success:
                    fulfill(response.result.value!)
                case .Failure(let error):
                    print("Error on GET request:", error)
                    reject(error)
                }
            }
        }
    }
    
    func GetHistory() -> Promise<JSON> {
        return GET("history")
    }
    
    func GetHistoryMapped() -> Promise<[HistoryResponse]> {
        let queryUrl = baseAPIURL+"history/period/2016-4-4"
        return Promise { fulfill, reject in
            self.manager!.request(.GET, queryUrl).responseArray { (response: Response<[HistoryResponse], NSError>) in
                switch response.result {
                case .Success:
                    if let historyArray = response.result.value {
                        print("HISTORYARRAY", historyArray)
                        fulfill(historyArray)
                    }
                case .Failure(let error):
                    print("Error on GET request:", error)
                    reject(error)
                }
            }
        }
    }
    
    func GetStates() -> Promise<[Entity]> {
        let queryUrl = baseAPIURL+"states"
        return Promise { fulfill, reject in
            self.manager!.request(.GET, queryUrl).responseArray { (response: Response<[Entity], NSError>) in
                switch response.result {
                case .Success:
                    fulfill(response.result.value!)
                case .Failure(let error):
                    print("Error on GET request:", error)
                    reject(error)
                }
            }
        }
    }
    
    func GetStateForEntityId(entityId: String) -> Promise<JSON> {
        return GET("states/"+entityId)
    }
    
    func GetStateForEntityIdMapped(entityId: String) -> Promise<Entity> {
        let queryUrl = baseAPIURL+"states/"+entityId
        return Promise { fulfill, reject in
            self.manager!.request(.GET, queryUrl).responseObject { (response: Response<Entity, NSError>) in
                switch response.result {
                case .Success:
                    fulfill(response.result.value!)
                case .Failure(let error):
                    print("Error on GET request:", error)
                    reject(error)
                }
            }
        }
    }
    
    func GetErrorLog() -> Promise<JSON> {
        return GET("error_log")
    }
    
    func SetState(entityId: String, state: String) -> Promise<JSON> {
        Whistle(Murmur(title: getEntityType(entityId)+" state set to "+state))
        return POST("states/"+entityId, parameters: ["state": state])
    }
    
    func CreateEvent(eventType: String, eventData: [String:AnyObject]) -> Promise<JSON> {
        Whistle(Murmur(title: eventType+" created"))
        return POST("events/"+eventType, parameters: eventData)
    }
    
    func CallService(domain: String, service: String, serviceData: [String:AnyObject]) -> Promise<JSON> {
//        Whistle(Murmur(title: domain+"/"+service+" called"))
        return POST("services/"+domain+"/"+service, parameters: serviceData)
    }
    
    func turnOn(entityId: String) -> Promise<JSON> {
        Whistle(Murmur(title: entityId+" turned on"))
        return CallService("homeassistant", service: "turn_on", serviceData: ["entity_id": entityId])
    }
    
    func turnOnEntity(entity: Entity) -> Promise<JSON> {
        var title = entity.ID
        if let friendlyName = entity.FriendlyName {
            title = friendlyName
        }
        Whistle(Murmur(title: title+" turned on"))
        return CallService("homeassistant", service: "turn_on", serviceData: ["entity_id": entity.ID])
    }
    
    func turnOff(entityId: String) -> Promise<JSON> {
        Whistle(Murmur(title: entityId+" turned off"))
        return CallService("homeassistant", service: "turn_off", serviceData: ["entity_id": entityId])
    }
    
    func turnOffEntity(entity: Entity) -> Promise<JSON> {
        var title = entity.ID
        if let friendlyName = entity.FriendlyName {
            title = friendlyName
        }
        Whistle(Murmur(title: title+" turned off"))
        return CallService("homeassistant", service: "turn_off", serviceData: ["entity_id": entity.ID])
    }
    
    func toggle(entityId: String) -> Promise<JSON> {
        Whistle(Murmur(title: entityId+" toggled"))
        return CallService("homeassistant", service: "toggle", serviceData: ["entity_id": entityId])
    }
    
    func toggleEntity(entity: Entity) -> Promise<JSON> {
        var title = entity.ID
        if let friendlyName = entity.FriendlyName {
            title = friendlyName
        }
        Whistle(Murmur(title: title+" toggled"))
        return CallService("homeassistant", service: "toggle", serviceData: ["entity_id": entity.ID])
    }
}