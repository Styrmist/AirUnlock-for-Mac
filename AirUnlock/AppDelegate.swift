//
//  AppDelegate.swift
//  AirUnlock
//
//  Created by Kirill on 08.10.2020.
//

import Cocoa
import CoreBluetooth
import IOBluetooth
import CoreFoundation
import IOKit
import Security
import ServiceManagement

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, CBPeripheralManagerDelegate, PanelControllerDelegate {
    
    // MARK: -
    private var peripheralManager: CBPeripheralManager?
    private var service: CBMutableService?
    private var menubarController: MenubarController!
    private var panelController: PanelController!
    private var bScreenLocked = false
    var kContextActivePanel: UnsafeMutableRawPointer?
    var authRef: AuthorizationRef?

    // MARK: -
    deinit {
        panelController.removeObserver(self, forKeyPath: "hasActivePanel")
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if context == kContextActivePanel {
            menubarController.hasActiveIcon = panelController.hasActivePanel
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // inital controler and BLE peripheral manager
        
        if panelController == nil {
            panelController = PanelController(delegate: self)
            panelController.addObserver(self, forKeyPath: "hasActivePanel", options: NSKeyValueObservingOptions.new, context: kContextActivePanel)
        }
        menubarController = MenubarController()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)

        // user's default keychain
        panelController.keychain = nil
        // inital keychain information
        panelController.keyChain_accountName = "AirUnlock"
        panelController.keyChain_serviceName = "AirUnlock"
        panelController.keyChain_passwordData = "AirUnlock"

        // check keychain access permission
        var password: Void? = nil
        var nLength: UInt32
        let status = SecKeychainFindGenericPassword(
            nil,
            UInt32(panelController.keyChain_serviceName.lengthOfBytes(using: .utf8)),
            panelController.keyChain_serviceName.utf8CString,
            UInt32(panelController.keyChain_accountName.lengthOfBytes(using: .utf8)),
            panelController.keyChain_accountName.utf8CString,
            &nLength,
            &password,
            nil)
        if status == noErr {
            panelController.keyChain_passwordData = String(bytes: password, encoding: .utf8)
        } else if status == errSecAuthFailed {
            
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "We need permission to store your password in system key chain."
            alert.addButton(withTitle: "Ok")
            alert.addButton(withTitle: "Exit")
            alert.alertStyle = .critical
            alert.icon = NSImage(named: "mbp-un")
            let button = alert.runModal()
            if button == .alertFirstButtonReturn {
                panelController.showUpdatePasswordDialog()
            }
        } else {
            print("\(SecCopyErrorMessageString(status, nil) as String)") // User canceled the operation.
        }
        if password != nil {
            SecKeychainItemFreeContent(nil, &password) // Free memory
        }
        
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(screenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil)
        center.addObserver(
            self,
            selector: #selector(screenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil)
        
        if IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateOFF {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Bluetooth Hardware is Off"
            alert.informativeText = "In order to use AirUnlock, the Bluetooth hardware must be on."
            alert.addButton(withTitle: "Turn Bluetooth On")
            alert.addButton(withTitle: "Leave Bluetooth Off")
            //[alert setShowsSuppressionButton:YES];
            let button = alert.runModal()

            if button == .alertFirstButtonReturn {
                IOBluetoothPreferenceSetControllerPowerState(1)
                //[[(id)NSClassFromString(@"IOBluetoothPreferences") performSelector:NSSelectorFromString(@"sharedPreferences") withObject:nil] performSelector:NSSelectorFromString(@"_setPoweredOn:") withObject:[NSNumber numberWithBool:YES]];
                //https://github.com/onmyway133/Runtime-Headers/blob/master/macOS/10.12/IOBluetooth.framework/IOBluetoothPreferences.h
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Explicitly remove the icon from the menu bar
        menubarController = nil
        return .terminateNow
    }
    
    // MARK: - Actions
    @IBAction func togglePanel(_ sender: Any?) {

        menubarController.hasActiveIcon = !menubarController.hasActiveIcon
        panelController.hasActivePanel = menubarController.hasActiveIcon
    }
    
    // MARK: - PanelControllerDelegate
    func statusItemView(for controller: PanelController?) -> StatusItemView? {
        return menubarController.statusItemView
    }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("peripheralManagerDidUpdateState: \(peripheral.state.rawValue)")
        
        if CBPeripheralManagerState.poweredOn == peripheral.state {
            //當藍牙打開
            // inital unlock setting for generate QR code
            // QR code encode content is BT's MAC Address, unlock Keyword, lock keyword
            // for exampele "AA-AA-AA-AA-AA-AA,unlock!,lock!"
            // we need to save these to avoid user scan qrcode when app relaunch
            let defaults = UserDefaults.standard
            
            let btAddress = IOBluetoothHostController.default().addressAsString()
            
            let appDefaults = [
                "ADDRESS" : btAddress,
                "LOCK" : "lock",
                "UNLOCK" : "unlock"
            ]
            defaults.register(defaults: appDefaults)
            
            
            peripheral.startAdvertising(
                [
                    CBAdvertisementDataLocalNameKey: "Air Unlock",
                    CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "BD0F6577-4A38-4D71-AF1B-4E8F57708080")]
            ])
            let characteristic = CBMutableCharacteristic(type: CBUUID(string: "A6282AC7-7FCA-4852-A2E6-1D69121FD44A"), properties: .write, value: nil, permissions: .writeable)
            
            let includedService = CBMutableService(type: CBUUID(string: "A5B288C3-FC55-491F-AF38-27D2F7D7BF25"), primary: true)
            
            includedService.characteristics = [characteristic]
            
            peripheralManager.add(includedService)
        } else {
            // 當藍芽被關地的時候或其他狀態
            
            peripheral.stopAdvertising()
            peripheral.removeAllServices()
        }
        
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            print("peripheralManagerDidStartAdvertising: \(error)")
        } else {
            print("peripheralManagerDidStartAdvertising:")
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            print("peripheralManagerDidAddService: \(service) \(error)")
        } else {
            print("peripheralManagerDidAddService: \(service)")
        }

    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        print("didReceiveWriteRequests")
        let request = requests[0]
        
        
        if request.characteristic.properties.rawValue & CBCharacteristicProperties.write.rawValue != 0 {
            //並沒有要真正改動值...只是拿來看一下符不符合解鎖的暗碼
            //CBMutableCharacteristic *c =(CBMutableCharacteristic *)request.characteristic;
            //c.value = request.value;
            
            
            
            var conetnt: String? = nil
            if let value = request.value {
                conetnt = String(data: value, encoding: .utf8)
            }
            let lockKeyword = UserDefaults.standard.string(forKey: "LOCK")
            let unlockKeyword = UserDefaults.standard.string(forKey: "UNLOCK")
            if (conetnt == lockKeyword) && !bScreenLocked {
                print("lock screen!")
                SACLockScreenImmediate()
                //10.10-10.12
                //NSBundle *bundle = [NSBundle bundleWithPath:@"/Applications/Utilities/Keychain Access.app/Contents/Resources/Keychain.menu"];
                //Class principalClass = [bundle principalClass];
                //id instance = [[principalClass alloc] init];
                //#pragma clang diagnostic push
                //#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                //[instance performSelector:NSSelectorFromString(@"_lockScreenMenuHit:") withObject:nil];
                //#pragma clang diagnostic pop
                sleep(3)
            } else if (conetnt == unlockKeyword) && bScreenLocked {
                print("unlock screen!")
                //wake up
                //need privileges (need to create helper)
                // sample code :https://developer.apple.com/library/mac/samplecode/EvenBetterAuthorizationSample/Introduction/Intro.html#//apple_ref/doc/uid/DTS40013768-Intro-DontLinkElementID_2
                //            IOPMAssertionID assertionID;
                //            IOPMAssertionDeclareUserActivity(CFSTR(""), kIOPMUserActiveLocal, &assertionID);
                //            CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
                //            CFDateRef wakeFromSleepAt = CFDateCreate(NULL, currentTime + 60);
                //            IOPMSchedulePowerEvent(wakeFromSleepAt,
                //                                    NULL,
                //                                    CFSTR(kIOPMAutoWake));
                // 10.10-10.12 can work for wake up with out privileges..
                var assertionID: IOPMAssertionID
                IOPMAssertionDeclareUserActivity("AirUnlock" as CFString, kIOPMUserActiveLocal, &assertionID)
                sleep(1)
                let unlockScript = "tell application \"System Events\" \nkeystroke \"\(panelController.keyChain_passwordData)\" \nkeystroke return \nend tell"
                let unlocker = NSAppleScript(source: unlockScript)
                //NSLog(unlockScript);
                unlocker?.executeAndReturnError(nil)
                IOPMAssertionRelease(assertionID)
            }
            peripheral.respond(to: request, withResult: .success)
        } else {
            peripheral.respond(to: request, withResult: .writeNotPermitted)
        }
    }
    
    
    @objc func screenLocked() {
        bScreenLocked = true
        print("Screen is locked!")
    }

    @objc func screenUnlocked() {
        bScreenLocked = false
        print("Screen is unlocked!")
    }
}

