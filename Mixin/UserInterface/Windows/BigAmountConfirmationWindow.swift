import Foundation
import MixinServices

class BigAmountConfirmationWindow: AssetConfirmationWindow {

    func render(asset: AssetItem, user: UserItem, amount: String, memo: String, fiatMoneyAmount: String? = nil, fromWeb: Bool, completion: @escaping CompletionHandler) -> BottomSheetView {

        titleLabel.text = R.string.localizable.transfer_large_title()
        tipsLabel.text = R.string.localizable.transfer_large_prompt(amountExchangeLabel.text ?? "", asset.symbol, user.fullName)
        
        return super.render(asset: asset, amount: amount, memo: memo, fiatMoneyAmount: fiatMoneyAmount, completion: completion)
    }

    static func instance() -> BigAmountConfirmationWindow {
        return Bundle.main.loadNibNamed("BigAmountConfirmationWindow", owner: nil, options: nil)?.first as! BigAmountConfirmationWindow
    }
}
