import UIKit

class NewAddressViewController: KeyboardBasedLayoutViewController {

    @IBOutlet weak var scrollView: UIScrollView!
    @IBOutlet weak var labelTextField: UITextField!
    @IBOutlet weak var addressTextView: PlaceholderTextView!
    @IBOutlet weak var memoTextView: PlaceholderTextView!
    @IBOutlet weak var memoScanButton: UIButton!
    @IBOutlet weak var saveButton: RoundedButton!
    @IBOutlet weak var assetView: AssetIconView!
    @IBOutlet weak var hintLabel: UILabel!
    @IBOutlet weak var continueWrapperView: UIView!

    @IBOutlet weak var opponentImageViewWidthConstraint: ScreenSizeCompatibleLayoutConstraint!
    @IBOutlet weak var continueWrapperBottomConstraint: NSLayoutConstraint!
    
    private var asset: AssetItem!
    private var addressValue: String {
        return addressTextView.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private var labelValue: String {
        return labelTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private var memoValue: String {
        return memoTextView.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private var isLegalAddress: Bool {
        return !addressValue.isEmpty && !labelValue.isEmpty && (noMemo || !memoValue.isEmpty)
    }
    private var successCallback: ((Address) -> Void)?
    private var address: Address?
    private var qrCodeScanningDestination: UIView?
    private var shouldLayoutWithKeyboard = true
    private var noMemo = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        addressTextView.delegate = self
        addressTextView.textContainerInset = .zero
        addressTextView.textContainer.lineFragmentPadding = 0
        if ScreenSize.current >= .inch6_1 {
            assetView.chainIconWidth = 28
            assetView.chainIconOutlineWidth = 4
        }
        assetView.setIcon(asset: asset)
        if let address = address {
            labelTextField.text = address.label
            addressTextView.text = address.destination
            memoTextView.text = address.tag
            checkLabelAndAddressAction(self)
            view.layoutIfNeeded()
            textViewDidChange(addressTextView)
            textViewDidChange(memoTextView)
        }

        if asset.isUseTag {
            memoTextView.placeholder = R.string.localizable.wallet_address_tag()
            hintLabel.text = ""
        } else {
            memoTextView.placeholder = R.string.localizable.wallet_address_memo()
            hintLabel.text = ""
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        shouldLayoutWithKeyboard = true
        labelTextField.becomeFirstResponder()
    }
    
    override func layout(for keyboardFrame: CGRect) {
        let windowHeight = AppDelegate.current.window.bounds.height
        let keyboardHeight = windowHeight - keyboardFrame.origin.y
        continueWrapperBottomConstraint.constant = keyboardHeight
        scrollView.contentInset.bottom = keyboardHeight + continueWrapperView.frame.height
        scrollView.scrollIndicatorInsets.bottom = keyboardHeight
        view.layoutIfNeeded()
        if !viewHasAppeared, ScreenSize.current <= .inch4 {
            scrollView.contentOffset.y = assetView.frame.maxY
        }
    }
    
    @IBAction func checkLabelAndAddressAction(_ sender: Any) {
        saveButton.isEnabled = isLegalAddress
    }

    @IBAction func scanAddressAction(_ sender: Any) {
        let vc = CameraViewController.instance()
        vc.delegate = self
        vc.scanQrCodeOnly = true
        navigationController?.pushViewController(vc, animated: true)
        qrCodeScanningDestination = addressTextView
    }

    @IBAction func scanMemoAction(_ sender: Any) {
        let vc = CameraViewController.instance()
        vc.delegate = self
        vc.scanQrCodeOnly = true
        navigationController?.pushViewController(vc, animated: true)
        qrCodeScanningDestination = memoTextView
    }
    
    @IBAction func saveAction(_ sender: Any) {
        guard isLegalAddress else {
            return
        }
        shouldLayoutWithKeyboard = false
        let assetId = asset.assetId
        let requestAddress = AddressRequest(assetId: assetId, destination: addressValue, tag: memoValue, label: labelValue, pin: "")
        AddressWindow.instance().presentPopupControllerAnimated(action: address == nil ? .add : .update, asset: asset, addressRequest: requestAddress, address: nil, dismissCallback: { [weak self] (success) in
            guard let weakSelf = self else {
                return
            }
            if success {
                weakSelf.navigationController?.popViewController(animated: true)
            } else {
                weakSelf.shouldLayoutWithKeyboard = true
                weakSelf.labelTextField.becomeFirstResponder()
            }
        })
    }
    
    class func instance(asset: AssetItem, address: Address? = nil, successCallback: ((Address) -> Void)? = nil) -> UIViewController {
        let vc = Storyboard.wallet.instantiateViewController(withIdentifier: "new_address") as! NewAddressViewController
        vc.asset = asset
        vc.successCallback = successCallback
        vc.address = address
        return ContainerViewController.instance(viewController: vc, title: address == nil ? Localized.ADDRESS_NEW_TITLE(symbol: asset.symbol) : Localized.ADDRESS_EDIT_TITLE(symbol: asset.symbol))
    }

}

extension NewAddressViewController: UITextViewDelegate {
    
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        return text != "\n"
    }
    
    func textViewDidChange(_ textView: UITextView) {
        checkLabelAndAddressAction(textView)
        view.layoutIfNeeded()
        let sizeToFit = CGSize(width: addressTextView.bounds.width,
                               height: UIView.layoutFittingExpandedSize.height)
        let contentSize = addressTextView.sizeThatFits(sizeToFit)
        addressTextView.isScrollEnabled = contentSize.height > addressTextView.frame.height
    }
    
}

extension NewAddressViewController: CameraViewControllerDelegate {
    
    func cameraViewController(_ controller: CameraViewController, shouldRecognizeString string: String) -> Bool {
        if qrCodeScanningDestination == addressTextView {
            addressTextView.text = standarizedAddress(from: string) ?? string
            textViewDidChange(addressTextView)
        } else if qrCodeScanningDestination == memoTextView {
            memoTextView.text = string
            textViewDidChange(memoTextView)
        }
        qrCodeScanningDestination = nil
        navigationController?.popViewController(animated: true)
        return false
    }
    
}

extension NewAddressViewController {
    
    private func standarizedAddress(from str: String) -> String? {
        guard str.hasPrefix("iban:XE") || str.hasPrefix("IBAN:XE") else {
            return str
        }
        guard str.count >= 20 else {
            return nil
        }
        
        let endIndex = str.firstIndex(of: "?") ?? str.endIndex
        let accountIdentifier = str[str.index(str.startIndex, offsetBy: 9)..<endIndex]
        
        guard let address = accountIdentifier.lowercased().base36to16() else {
            return nil
        }
        return "0x\(address)"
    }
    
}

private extension String {
    
    private static let base36Alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    
    private static var base36AlphabetMap: [Character: Int] = {
        var reverseLookup = [Character: Int]()
        for characterIndex in 0..<String.base36Alphabet.count {
            let character = base36Alphabet[base36Alphabet.index(base36Alphabet.startIndex, offsetBy: characterIndex)]
            reverseLookup[character] = characterIndex
        }
        return reverseLookup
    }()
    
    func base36to16() -> String? {
        var bytes = [Int]()
        for character in self {
            guard var carry = String.base36AlphabetMap[character] else {
                return nil
            }
            
            for byteIndex in 0..<bytes.count {
                carry += bytes[byteIndex] * 36
                bytes[byteIndex] = carry & 0xff
                carry >>= 8
            }
            
            while carry > 0 {
                bytes.append(carry & 0xff)
                carry >>= 8
            }
        }
        return bytes.reversed().map { String(format: "%02hhx", $0) }.joined()
    }
    
}
