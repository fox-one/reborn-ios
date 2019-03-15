import UIKit

class WalletPasswordViewController: UIViewController {

    @IBOutlet weak var pinField: PinField!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var subtitleLabel: UILabel!
    @IBOutlet weak var backButton: UIButton!
    @IBOutlet weak var nextButton: StateResponsiveButton!
    
    @IBOutlet weak var bottomConstraint: NSLayoutConstraint!
    
    enum WalletPasswordType {
        case initPinStep1
        case initPinStep2(previous: String)
        case initPinStep3(previous: String)
        case changePinStep1
        case changePinStep2(old: String)
        case changePinStep3(old: String, previous: String)
        case changePinStep4(old: String, previous: String)
    }

    private var transferData: PasswordTransferData?
    private var walletPasswordType = WalletPasswordType.initPinStep1

    override func viewDidLoad() {
        super.viewDidLoad()
        pinField.delegate = self
        pinField.becomeFirstResponder()
        nextButton.activityIndicator.style = .white

        switch walletPasswordType {
        case .initPinStep1:
            titleLabel.text = Localized.WALLET_PIN_CREATE_TITLE
            subtitleLabel.text = ""
            backButton.setImage(R.image.ic_title_close(), for: .normal)
        case .initPinStep2, .changePinStep3:
            titleLabel.text = Localized.WALLET_PIN_CONFIRM_TITLE
            subtitleLabel.text = Localized.WALLET_PIN_CONFIRM_SUBTITLE
            backButton.setImage(R.image.ic_title_back(), for: .normal)
        case .initPinStep3, .changePinStep4:
            titleLabel.text = Localized.WALLET_PIN_CONFIRM_AGAIN_TITLE
            subtitleLabel.text = Localized.WALLET_PIN_CONFIRM_AGAIN_SUBTITLE
            backButton.setImage(R.image.ic_title_back(), for: .normal)
        case .changePinStep1:
            titleLabel.text = Localized.WALLET_PIN_VERIFY_TITLE
            subtitleLabel.text = ""
            backButton.setImage(R.image.ic_title_close(), for: .normal)
        case .changePinStep2:
            titleLabel.text = Localized.WALLET_PIN_NEW_TITLE
            subtitleLabel.text = ""
            backButton.setImage(R.image.ic_title_back(), for: .normal)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if !pinField.isFirstResponder {
            pinField.becomeFirstResponder()
        }
        pinField.clear()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @IBAction func pinChangedAction(_ sender: Any) {
        nextButton.isEnabled = pinField.text.count == pinField.numberOfDigits
    }

    @IBAction func backAction(_ sender: Any) {
        navigationController?.popViewController(animated: true)
    }

    class func instance(walletPasswordType: WalletPasswordType, transferData: PasswordTransferData? = nil) -> UIViewController {
        let vc = Storyboard.wallet.instantiateViewController(withIdentifier: "password") as! WalletPasswordViewController
        vc.walletPasswordType = walletPasswordType
        vc.transferData = transferData
        return vc
    }

    @objc func keyboardWillChangeFrame(_ notification: Notification) {
        let endFrame: CGRect = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let windowHeight = AppDelegate.current.window!.bounds.height
        self.bottomConstraint.constant = windowHeight - endFrame.origin.y + 20
        UIView.animate(withDuration: 0.15) {
            self.view.layoutIfNeeded()
        }
    }

    class func instance(fromChat user: UserItem) -> UIViewController {
        let vc = Storyboard.wallet.instantiateViewController(withIdentifier: "password") as! WalletPasswordViewController
        vc.walletPasswordType = .initPinStep1
        vc.transferData = PasswordTransferData(user: user)
        return vc
    }

    private func popToFirstInitController() {
        guard let viewController = navigationController?.viewControllers.first(where: { $0 is WalletPasswordViewController }) else {
            return
        }
        navigationController?.popToViewController(viewController, animated: true)
    }

    private func updatePasswordSuccessfully(alertTitle: String) {
        alert(alertTitle, cancelHandler: { [weak self](_) in
            guard let weakSelf = self else {
                return
            }
            if let transferData = weakSelf.transferData {
                self?.navigationController?.pushViewController(withBackChat: SendViewController.instance(asset: nil, type: .contact(transferData.user)))
            } else {
                self?.navigationController?.pushViewController(withBackRoot: WalletViewController.instance())
            }
        })
    }

    struct PasswordTransferData {
        let user: UserItem!
    }
}

extension WalletPasswordViewController: MixinNavigationAnimating {
    
    var pushAnimation: MixinNavigationPushAnimation {
        switch walletPasswordType {
        case .changePinStep1, .initPinStep1:
            return .present
        default:
            return .push
        }
    }
    
    var popAnimation: MixinNavigationPopAnimation {
        switch walletPasswordType {
        case .changePinStep1, .initPinStep1:
            return .dismiss
        default:
            return .pop
        }
    }

}

extension WalletPasswordViewController: PinFieldDelegate {

    func inputFinished(pin: String) {
        guard !nextButton.isBusy else {
            return
        }
        let pin = pinField.text

        switch walletPasswordType {
        case .initPinStep1, .changePinStep2:
            if pin == "123456" || Set(pin).count < 3 {
                pinField.clear()
                alert(Localized.WALLET_PIN_TOO_SIMPLE)
                return
            }
        default:
            break
        }

        switch walletPasswordType {
        case .initPinStep1:
            let vc = WalletPasswordViewController.instance(walletPasswordType: .initPinStep2(previous: pin), transferData: transferData)
            navigationController?.pushViewController(vc, animated: true)
        case .initPinStep2(let previous):
            if previous == pin {
                let vc = WalletPasswordViewController.instance(walletPasswordType: .initPinStep3(previous: pin), transferData: transferData)
                navigationController?.pushViewController(vc, animated: true)
            } else {
                alert(Localized.WALLET_PIN_INCONSISTENCY, cancelHandler: { [weak self](_) in
                    self?.popToFirstInitController()
                })
            }
        case .initPinStep3(let previous):
            if previous == pin {
                nextButton.isHidden = false
                nextButton.isBusy = true
                AccountAPI.shared.updatePin(old: nil, new: pin, completion: { [weak self] (result) in
                    self?.nextButton.isBusy = false
                    switch result {
                    case .success(let account):
                        WalletUserDefault.shared.lastInputPinTime = Date().timeIntervalSince1970
                        AccountAPI.shared.account = account
                        self?.updatePasswordSuccessfully(alertTitle: Localized.WALLET_SET_PASSWORD_SUCCESS)
                    case let .failure(error):
                        self?.alert(error.localizedDescription)
                    }
                })
            } else {
                alert(Localized.WALLET_PIN_INCONSISTENCY, cancelHandler: { [weak self](_) in
                    self?.popToFirstInitController()
                })
            }
        case .changePinStep1:
            nextButton.isHidden = false
            nextButton.isBusy = true
            AccountAPI.shared.verify(pin: pin, completion: { [weak self] (result) in
                guard let weakSelf = self else {
                    return
                }
                weakSelf.nextButton.isBusy = false
                switch result {
                case .success:
                    WalletUserDefault.shared.lastInputPinTime = Date().timeIntervalSince1970
                    let vc = WalletPasswordViewController.instance(walletPasswordType: .changePinStep2(old: pin), transferData: weakSelf.transferData)
                    weakSelf.navigationController?.pushViewController(vc, animated: true)
                case let .failure(error):
                    weakSelf.pinField.clear()
                    weakSelf.alert(error.localizedDescription)
                }
            })
        case .changePinStep2(let old):
            let vc = WalletPasswordViewController.instance(walletPasswordType: .changePinStep3(old: old, previous: pin), transferData: transferData)
            navigationController?.pushViewController(vc, animated: true)
        case .changePinStep3(let old, let previous):
            if previous == pin {
                let vc = WalletPasswordViewController.instance(walletPasswordType: .changePinStep4(old: old, previous: pin), transferData: transferData)
                navigationController?.pushViewController(vc, animated: true)
            } else {
                alert(Localized.WALLET_PIN_INCONSISTENCY, cancelHandler: { [weak self](_) in
                    self?.popToFirstInitController()
                })
            }
        case .changePinStep4(let old, let previous):
            if previous == pin {
                nextButton.isHidden = false
                nextButton.isBusy = true
                AccountAPI.shared.updatePin(old: old, new: pin, completion: { [weak self] (result) in
                    self?.nextButton.isBusy = false
                    switch result {
                    case .success(let account):
                        if WalletUserDefault.shared.isBiometricPay {
                            Keychain.shared.storePIN(pin: pin)
                        }
                        WalletUserDefault.shared.checkPinInterval = WalletUserDefault.shared.checkMinInterval
                        WalletUserDefault.shared.lastInputPinTime = Date().timeIntervalSince1970
                        AccountAPI.shared.account = account
                        self?.updatePasswordSuccessfully(alertTitle: Localized.WALLET_CHANGE_PASSWORD_SUCCESS)
                    case let .failure(error):
                        self?.alert(error.localizedDescription)
                    }
                })
            } else {
                alert(Localized.WALLET_PIN_INCONSISTENCY, cancelHandler: { [weak self](_) in
                    self?.navigationController?.popViewController(animated: true)
                })
            }
        }
    }
}
