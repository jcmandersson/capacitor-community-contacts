import Foundation
import Capacitor
import Contacts
import ContactsUI

enum CallingMethod {
    case GetContact
    case GetContacts
    case CreateContact
    case DeleteContact
    case PickContact
}

@objc(ContactsPlugin)
public class ContactsPlugin: CAPPlugin, CNContactPickerDelegate {
    private let implementation = Contacts()

    private var callingMethod: CallingMethod?

    private var pickContactCallbackId: String?

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        let permissionState: String

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            permissionState = "prompt"
        case .restricted, .denied:
            permissionState = "denied"
        case .authorized:
            permissionState = "granted"
        case .limited:
            permissionState = "limited"
        @unknown default:
            permissionState = "prompt"
        }

        call.resolve([
            "contacts": permissionState
        ])
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        CNContactStore().requestAccess(for: .contacts) { [weak self] _, _  in
            self?.checkPermissions(call)
        }
    }

    private func requestContactsPermission(_ call: CAPPluginCall, _ callingMethod: CallingMethod) {
        self.callingMethod = callingMethod
        if isContactsPermissionGranted() {
            permissionCallback(call)
        } else {
            CNContactStore().requestAccess(for: .contacts) { [weak self] _, _  in
                self?.permissionCallback(call)
            }
        }
    }

    private func isContactsPermissionGranted() -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined, .restricted, .denied:
            return false
        case .authorized, .limited:
            return true
        @unknown default:
            return false
        }
    }

    private func permissionCallback(_ call: CAPPluginCall) {
        let method = self.callingMethod

        self.callingMethod = nil

        if !isContactsPermissionGranted() {
            call.reject("Permission is required to access contacts.")
            return
        }

        switch method {
        case .GetContact:
            getContact(call)
        case .GetContacts:
            getContacts(call)
        case .CreateContact:
            createContact(call)
        case .DeleteContact:
            deleteContact(call)
        case .PickContact:
            pickContact(call)
        default:
            // No method was being called,
            // so nothing has to be done here.
            break
        }
    }

    @objc func getContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.GetContact)
        } else {
            let contactId = call.getString("contactId")

            guard let contactId = contactId else {
                call.reject("Parameter `contactId` not provided.")
                return
            }

            let projectionInput = GetContactsProjectionInput(call.getObject("projection") ?? JSObject())

            let contact = implementation.getContact(contactId, projectionInput)

            guard let contact = contact else {
                call.reject("Contact not found.")
                return
            }

            call.resolve([
                "contact": contact.getJSObject()
            ])
        }
    }

    @objc func getContacts(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.GetContacts)
        } else {
            let projectionInput = GetContactsProjectionInput(call.getObject("projection") ?? JSObject())

            let contacts = implementation.getContacts(projectionInput)

            var contactsJSArray: JSArray = JSArray()

            for contact in contacts {
                contactsJSArray.append(contact.getJSObject())
            }

            call.resolve([
                "contacts": contactsJSArray
            ])
        }
    }

    @objc func createContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.CreateContact)
        } else {
            let contactInput = CreateContactInput.init(call.getObject("contact", JSObject()))

            let contactId = implementation.createContact(contactInput)

            guard let contactId = contactId else {
                call.reject("Something went wrong.")
                return
            }

            call.resolve([
                "contactId": contactId
            ])
        }
    }

    @objc func deleteContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.DeleteContact)
        } else {
            let contactId = call.getString("contactId")

            guard let contactId = contactId else {
                call.reject("Parameter `contactId` not provided.")
                return
            }

            if !implementation.deleteContact(contactId) {
                call.reject("Something went wrong.")
                return
            }

            call.resolve()
        }
    }

    @objc func pickContact(_ call: CAPPluginCall) {
        if !isContactsPermissionGranted() {
            requestContactsPermission(call, CallingMethod.PickContact)
        } else {
            DispatchQueue.main.async {
                // Save the call and its callback id
                self.bridge?.saveCall(call)
                self.pickContactCallbackId = call.callbackId

                // Initialize the contact picker for single selection
                let contactPicker = CNContactPickerViewController()
                // Mark current class as the delegate class,
                // this will make the callback `contactPicker` actually work.
                contactPicker.delegate = self
                
                // Configure for single selection only
                contactPicker.predicateForSelectionOfContact = NSPredicate(value: true)
                
                // Present (open) the native contact picker.
                self.bridge?.viewController?.present(contactPicker, animated: true)
            }
        }
    }

    public func contactPicker(_ picker: CNContactPickerViewController, didSelect selectedContact: CNContact) {
        // Dismiss the picker
        picker.dismiss(animated: true)
        
        guard let callbackId = self.pickContactCallbackId else {
            return
        }
        
        let call = self.bridge?.savedCall(withID: callbackId)

        guard let call = call else {
            return
        }

        // Check if this is a limited access request or regular pick contact
        let callMethod = call.method ?? ""
        
        if callMethod == "requestLimitedContactsAccess" {
            // For limited access, return full contact data in an array (even for single selection)
            let contact = ContactPayload(selectedContact.identifier)
            contact.fillData(selectedContact)
            
            call.resolve([
                "contacts": [contact.getJSObject()]
            ])
        } else if callMethod == "pickContact" {
            // For regular pick contact, return the full contact data
            let contact = ContactPayload(selectedContact.identifier)
            contact.fillData(selectedContact)
            
            call.resolve([
                "contact": contact.getJSObject()
            ])
        } else {
            // Unknown method
            call.reject("Unknown contact picker method: \(callMethod)")
        }

        self.bridge?.releaseCall(call)
        
        // Clean up the callback ID
        self.pickContactCallbackId = nil
    }
    
    public func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
        // Dismiss the picker
        picker.dismiss(animated: true)
        
        guard let callbackId = self.pickContactCallbackId else {
            return
        }
        
        let call = self.bridge?.savedCall(withID: callbackId)

        guard let call = call else {
            return
        }

        // Return full contact data for all methods - much simpler!
        var contactsArray: [JSObject] = []
        for selectedContact in contacts {
            let contact = ContactPayload(selectedContact.identifier)
            contact.fillData(selectedContact)
            contactsArray.append(contact.getJSObject())
        }

        call.resolve([
            "contacts": contactsArray
        ])

        self.bridge?.releaseCall(call)
        
        // Clean up the callback ID
        self.pickContactCallbackId = nil
    }
    
    public func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        // Picker will dismiss automatically on cancel
        
        guard let callbackId = self.pickContactCallbackId else {
            return
        }
        
        let call = self.bridge?.savedCall(withID: callbackId)

        guard let call = call else {
            return
        }

        // Check if this is a limited access request or regular pick contact
        let callMethod = call.method ?? ""
        
        if callMethod == "requestLimitedContactsAccess" {
            // For limited access, return empty array (not an error)
            call.resolve([
                "contacts": []
            ])
        } else if callMethod == "pickContact" {
            // For regular pick contact, reject the call
            call.reject("User cancelled contact selection")
        } else {
            // Unknown method - reject with error
            call.reject("Unknown contact picker method: \(callMethod)")
        }

        self.bridge?.releaseCall(call)
        
        // Clean up the callback ID
        self.pickContactCallbackId = nil
    }

    @objc func requestLimitedContactsAccess(_ call: CAPPluginCall) {
        if #available(iOS 18.0, *) {
            let authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
            
            switch authorizationStatus {
            case .limited, .notDetermined:
                // Request additional contacts using the new iOS 18 API
                self.presentContactAccessPicker(call)
            case .authorized:
                // Already have full access, no need to request limited access
                call.resolve([
                    "contacts": []
                ])
            case .restricted, .denied:
                call.reject("Contact access is denied or restricted.")
            @unknown default:
                call.reject("Unknown authorization status.")
            }
        } else {
            call.reject("Limited contacts access is not supported on this iOS version. iOS 18+ required.")
        }
    }

    @available(iOS 18.0, *)
    private func presentContactAccessPicker(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            // Present contact picker for limited access selection (multiple selection)
            let contactPicker = CNContactPickerViewController()
            contactPicker.delegate = self
            
            // Configure for multiple selection:
            // - Set predicateForEnablingContact to allow contact selection
            // - DO NOT set predicateForSelectionOfContact (this would force single selection)
            contactPicker.predicateForEnablingContact = NSPredicate(value: true)
            
            // Store the call for later use
            self.bridge?.saveCall(call)
            self.pickContactCallbackId = call.callbackId
            
            self.bridge?.viewController?.present(contactPicker, animated: true)
        }
    }

    @objc func isLimitedContactsAccessSupported(_ call: CAPPluginCall) {
        if #available(iOS 18.0, *) {
            call.resolve(["supported": true])
        } else {
            call.resolve(["supported": false])
        }
    }
}
