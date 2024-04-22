//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC404} from "./interfaces/IERC404.sol";
import {ERC721Receiver} from "./lib/ERC721Receiver.sol";
import {DoubleEndedQueue} from "./lib/DoubleEndedQueue.sol";
import {IERC165} from "./lib/interfaces/IERC165.sol";

abstract contract ERC404 is IERC404 {
  using DoubleEndedQueue for DoubleEndedQueue.Uint256Deque;

  /// @dev The queue of ERC-721 tokens stored in the contract.
  /// 컨트랙트에 저장된 ERC-721 토큰의 대기열
  DoubleEndedQueue.Uint256Deque private _storedERC721Ids;

  /// @dev Token name
  /// 토큰 이름
  string public name;

  /// @dev Token symbol
  /// 토큰 심볼
  string public symbol;

  /// @dev Decimals for ERC-20 representation
  /// ERC-20 표현을 위한 소수점 자리수
  uint8 public immutable decimals;

  /// @dev Units for ERC-20 representation
  /// ERC-20 표현을 위한 단위
  uint256 public immutable units;

  /// @dev Total supply in ERC-20 representation
  /// ERC-20 표현의 총 공급량
  uint256 public totalSupply;

  /// @dev Current mint counter which also represents the highest
  ///      minted id, monotonically increasing to ensure accurate ownership
  /// 현재 발행된 최고 ID를 나타내는 발행 카운터, 소유권을 정확하게 보장하기 위해 단조롭게 증가
  uint256 internal _minted;

  /// @dev Initial chain id for EIP-2612 support
  /// EIP-2612 지원을 위한 초기 체인 ID
  uint256 internal immutable INITIAL_CHAIN_ID;

  /// @dev Initial domain separator for EIP-2612 support
  /// EIP-2612 지원을 위한 초기 도메인 분리자
  bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

  /// @dev Balance of user in ERC-20 representation
  /// 사용자의 ERC-20 표현에 대한 잔액
  mapping(address => uint256) public balanceOf;

  /// @dev Allowance of user in ERC-20 representation
  /// 사용자의 ERC-20 표현에 대한 허용량
  mapping(address => mapping(address => uint256)) public allowance;

  /// @dev Approval in ERC-721 representaion
  /// ERC-721 표현에 대한 승인
  mapping(uint256 => address) public getApproved;

  /// @dev Approval for all in ERC-721 representation
  /// 모든 ERC-721 표현에 대한 승인
  mapping(address => mapping(address => bool)) public isApprovedForAll;

  /// @dev Packed representation of ownerOf and owned indices
  /// 소유자와 소유된 인덱스의 포장된 표현
  mapping(uint256 => uint256) internal _ownedData;

  /// @dev Array of owned ids in ERC-721 representation
  /// ERC-721 표현의 소유 ID 배열
  mapping(address => uint256[]) internal _owned;

  /// @dev Addresses that are exempt from ERC-721 transfer, typically for gas savings (pairs, routers, etc)
  /// 일반적으로 가스 절약을 위해 ERC-721 전송이 면제되는 주소
  mapping(address => bool) public erc721TransferExempt;

  /// @dev EIP-2612 nonces
  /// EIP-2612 논스
  mapping(address => uint256) public nonces;

  /// @dev Address bitmask for packed ownership data
  /// 포장된 소유권 데이터에 대한 주소 비트마스크
  uint256 private constant _BITMASK_ADDRESS = (1 << 160) - 1;

  /// @dev Owned index bitmask for packed ownership data
  /// 포장된 소유권 데이터에 대한 소유된 인덱스 비트마스크
  uint256 private constant _BITMASK_OWNED_INDEX = ((1 << 96) - 1) << 160;

  constructor(string memory name_, string memory symbol_, uint8 decimals_) {
    name = name_;
    symbol = symbol_;

    if (decimals_ < 18) {
      revert DecimalsTooLow();
    }

    decimals = decimals_;
    units = 10 ** decimals;

    // EIP-2612 initialization
    INITIAL_CHAIN_ID = block.chainid;
    INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
  }

  /// @notice Function to find owner of a given ERC-721 token
  /// 특정 ERC-721 토큰의 소유자를 찾는 함수
  function ownerOf(
    uint256 id_
  ) public view virtual returns (address erc721Owner) {
    erc721Owner = _getOwnerOf(id_);

    // If the id_ is beyond the range of minted tokens, is 0, or the token is not owned by anyone, revert.
    // id_가 발행된 토큰 범위를 벗어나거나, 0이거나, 토큰을 누구도 소유하지 않은 경우 되돌린다.
    if (id_ > _minted || id_ == 0 || erc721Owner == address(0)) {
      revert NotFound();
    }
  }

  function owned(
    address owner_
  ) public view virtual returns (uint256[] memory) {
    return _owned[owner_];
  }

  function erc721BalanceOf(
    address owner_
  ) public view virtual returns (uint256) {
    return _owned[owner_].length;
  }

  function erc20BalanceOf(
    address owner_
  ) public view virtual returns (uint256) {
    return balanceOf[owner_];
  }

  function erc20TotalSupply() public view virtual returns (uint256) {
    return totalSupply;
  }

  function erc721TotalSupply() public view virtual returns (uint256) {
    return _minted;
  }

  function erc721TokensBankedInQueue() public view virtual returns (uint256) {
    return _storedERC721Ids.length();
  }

  /// @notice tokenURI must be implemented by child contract
  /// tokenURI는 자식 계약으로 구현되어야 한다.
  function tokenURI(uint256 id_) public view virtual returns (string memory);

  /// @notice Function for token approvals
  /// @dev This function assumes the operator is attempting to approve an ERC-721
  ///      if valueOrId is less than the minted count. Note: Unlike setApprovalForAll,
  ///      spender_ must be allowed to be 0x0 so that approval can be revoked.
  /// 토큰 승인을 위한 함수
  /// 이 함수는 valueOrId가 발행된 개수보다 작은 경우 ERC-721 승인을 시도한다고 가정한다.
  /// 참고: setApprovalForAll과 달리 spender_는 승인이 취소될 수 있도록 0x0이 되도록 허용되어야 한다.
  function approve(
    address spender_,
    uint256 valueOrId_
  ) public virtual returns (bool) {
    // The ERC-721 tokens are 1-indexed, so 0 is not a valid id and indicates that
    // operator is attempting to set the ERC-20 allowance to 0.
    // ERC-721 토큰은 1부터 시작하므로 0은 유효한 ID가 아니며 ERC-20 허용량을 0으로 설정하려는 것을 나타낸다.
    if (valueOrId_ <= _minted && valueOrId_ > 0) {
      // Intention is to approve as ERC-721 token (id).
      // ERC-721 토큰 (id)으로 승인하려는 의도.
      uint256 id = valueOrId_;
      address erc721Owner = _getOwnerOf(id);

      if (
        msg.sender != erc721Owner && !isApprovedForAll[erc721Owner][msg.sender]
      ) {
        revert Unauthorized();
      }

      getApproved[id] = spender_;

      emit ERC721Approval(erc721Owner, spender_, id);
    } else {
      // Prevent granting 0x0 an ERC-20 allowance.
      // 0x0에 ERC-20 허용을 부여하는것을 방지
      if (spender_ == address(0)) {
        revert InvalidSpender();
      }

      // Intention is to approve as ERC-20 token (value).
      // ERC-20 토큰 (값)으로 승인하려는 의도
      uint256 value = valueOrId_;
      allowance[msg.sender][spender_] = value;

      emit ERC20Approval(msg.sender, spender_, value);
    }

    return true;
  }

  /// @notice Function for ERC-721 approvals
  /// ERC-721 전체 승인을 위한 함수
  function setApprovalForAll(address operator_, bool approved_) public virtual {
    // Prevent approvals to 0x0.
    // 0x0에 대한 승인을 방지
    if (operator_ == address(0)) {
      revert InvalidOperator();
    }
    isApprovedForAll[msg.sender][operator_] = approved_;
    emit ApprovalForAll(msg.sender, operator_, approved_);
  }

  /// @notice Function for mixed transfers from an operator that may be different than 'from'.
  /// @dev This function assumes the operator is attempting to transfer an ERC-721
  ///      if valueOrId is less than or equal to current max id.
  /// 'from'과 다를 수 있는 연산자의 혼합 전송을 위한 함수
  /// 이 함수는 valueOrId가 현재 최대 ID보다 작거나 같은 경우 ERC-721 전송을 시도한다고 가정한다.
  function transferFrom(
    address from_,
    address to_,
    uint256 valueOrId_
  ) public virtual returns (bool) {
    // Prevent transferring tokens from 0x0.
    // 0x0에서 토큰을 전송하는 것을 방지
    if (from_ == address(0)) {
      revert InvalidSender();
    }

    // Prevent burning tokens to 0x0.
    // 0x0으로 토큰을 소각하는 것을 방지
    if (to_ == address(0)) {
      revert InvalidRecipient();
    }

    if (valueOrId_ <= _minted) {
      // Intention is to transfer as ERC-721 token (id).
      // ERC-721 토큰 (ID)으로 전송하려는 의도
      uint256 id = valueOrId_;

      if (from_ != _getOwnerOf(id)) {
        revert Unauthorized();
      }

      // Check that the operator is either the sender or approved for the transfer.
      // 연산자가 전송자이거나 전송에 대해 승인되었거나 getApproved[id]인지 확인한다.
      if (
        msg.sender != from_ &&
        !isApprovedForAll[from_][msg.sender] &&
        msg.sender != getApproved[id]
      ) {
        revert Unauthorized();
      }

      // Neither the sender nor the recipient can be ERC-721 transfer exempt when transferring specific token ids.
      // 전송자와 수신자는 특정 토큰 ID를 전송할 때 ERC-721 전송 면제 대상이 될 수 없다.
      if (erc721TransferExempt[from_]) {
        revert SenderIsERC721TransferExempt();
      }

      if (erc721TransferExempt[to_]) {
        revert RecipientIsERC721TransferExempt();
      }

      // Transfer 1 * units ERC-20 and 1 ERC-721 token.
      // ERC-721 transfer exemptions handled above. Can't make it to this point if either is transfer exempt.
      // 1 * units ERC-20과 1 ERC-721 토큰을 전송
      // ERC-721 전송 면제는 위에서 처리된다. 이 지점에 도달하면 어느 쪽도 전송 면제 대상이 될 수 없다.
      _transferERC20(from_, to_, units);
      _transferERC721(from_, to_, id);
    } else {
      // Intention is to transfer as ERC-20 token (value).
      // ERC-20 토큰 (값)으로 전송하려는 의도
      uint256 value = valueOrId_;
      uint256 allowed = allowance[from_][msg.sender];

      // Check that the operator has sufficient allowance.
      // 연산자가 충분한 허용량을 가지고 있는지 확인
      if (allowed != type(uint256).max) {
        allowance[from_][msg.sender] = allowed - value;
      }

      // Transferring ERC-20s directly requires the _transfer function.
      // Handles ERC-721 exemptions internally.
      // ERC-20을 직접 전송하려면 _transfer 함수가 필요
      // ERC-721 면제는 내부적으로 처리된다.
      _transferERC20WithERC721(from_, to_, value);
    }

    return true;
  }

  /// @notice Function for ERC-20 transfers.
  /// @dev This function assumes the operator is attempting to transfer as ERC-20
  ///      given this function is only supported on the ERC-20 interface. 
  ///      Treats even small amounts that are valid ERC-721 ids as ERC-20s.
  /// ERC-20 전송을 위한 함수
  /// 이 함수는 연산자가 ERC-20으로 전송하려고 시도한다고 가정한다.
  /// 이 함수는 ERC-20 인터페이스에서만 지원된다.
  /// 유효한 ERC-721 ids인 소량이라도 ERC-20으로 처리한다.
  function transfer(address to_, uint256 value_) public virtual returns (bool) {
    // Prevent burning tokens to 0x0.
    if (to_ == address(0)) {
      revert InvalidRecipient();
    }

    // Transferring ERC-20s directly requires the _transfer function.
    // Handles ERC-721 exemptions internally.
    // ERC-20을 직접 전송하려면 _transfer 함수가 필요하다.
    // ERC-721 면제는 내부적으로 처리된다.
    return _transferERC20WithERC721(msg.sender, to_, value_);
  }

  /// @notice Function for ERC-721 transfers with contract support.
  /// This function only supports moving valid ERC-721 ids, as it does not exist on the ERC-20 spec and will revert otherwise.
  /// 계약 지원과 함께 ERC-721 전송을 위한 함수
  /// 이 함수는 유효한 ERC-721 ID만 이동할 수 있으며, 그렇지 않으면 되돌린다.
  function safeTransferFrom(
    address from_,
    address to_,
    uint256 id_
  ) public virtual {
    safeTransferFrom(from_, to_, id_, "");
  }

  /// @notice Function for ERC-721 transfers with contract support and callback data.
  /// This function only supports moving valid ERC-721 ids, as it does not exist on the ERC-20 spec and will revert otherwise.
  /// 계약 지원과 콜백 데이터를 사용한 ERC-721 전송을 위한 함수
  /// 이 함수는 유효한 ERC-721 ID만 이동할 수 있으며, 그렇지 않으면 되돌립니다.
  function safeTransferFrom(
    address from_,
    address to_,
    uint256 id_,
    bytes memory data_
  ) public virtual {
    if (id_ > _minted || id_ == 0) {
      revert InvalidId();
    }

    transferFrom(from_, to_, id_);

    if (
      to_.code.length != 0 &&
      ERC721Receiver(to_).onERC721Received(msg.sender, from_, id_, data_) !=
      ERC721Receiver.onERC721Received.selector
    ) {
      revert UnsafeRecipient();
    }
  }

  /// @notice Function for EIP-2612 permits
  /// EIP-2612 허가를 위한 함수
  function permit(
    address owner_,
    address spender_,
    uint256 value_,
    uint256 deadline_,
    uint8 v_,
    bytes32 r_,
    bytes32 s_
  ) public virtual {
    if (deadline_ < block.timestamp) {
      revert PermitDeadlineExpired();
    }

    if (value_ <= _minted && value_ > 0) {
      revert InvalidApproval();
    }

    if (spender_ == address(0)) {
      revert InvalidSpender();
    }

    unchecked {
      address recoveredAddress = ecrecover(
        keccak256(
          abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR(),
            keccak256(
              abi.encode(
                keccak256(
                  "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner_,
                spender_,
                value_,
                nonces[owner_]++,
                deadline_
              )
            )
          )
        ),
        v_,
        r_,
        s_
      );

      if (recoveredAddress == address(0) || recoveredAddress != owner_) {
        revert InvalidSigner();
      }

      allowance[recoveredAddress][spender_] = value_;
    }

    emit ERC20Approval(owner_, spender_, value_);
  }

  /// @notice Returns domain initial domain separator, or recomputes if chain id is not equal to initial chain id
  /// 초기 도메인 분리자를 반환하거나 체인 ID가 초기 체인 ID와 같지 않은 경우 재계산한다.
  function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
    return
      block.chainid == INITIAL_CHAIN_ID
        ? INITIAL_DOMAIN_SEPARATOR
        : _computeDomainSeparator();
  }

  function supportsInterface(
    bytes4 interfaceId
  ) public view virtual returns (bool) {
    return
      interfaceId == type(IERC404).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @notice Internal function to compute domain separator for EIP-2612 permits
  /// EIP-2612 허가를 위한 도메인 분리자를 계산하는 내부 함수
  function _computeDomainSeparator() internal view virtual returns (bytes32) {
    return
      keccak256(
        abi.encode(
          keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
          ),
          keccak256(bytes(name)),
          keccak256("1"),
          block.chainid,
          address(this)
        )
      );
  }

  /// @notice This is the lowest level ERC-20 transfer function, which
  ///         should be used for both normal ERC-20 transfers as well as minting.
  /// Note that this function allows transfers to and from 0x0.
  /// 이것은 가장 낮은 수준의 ERC-20 전송 함수로, 일반 ERC-20 전송뿐만 아니라 발행에도 사용해야 한다.
  /// 참고: 이 함수는 0x0으로 전송을 허용한다.
  function _transferERC20(
    address from_,
    address to_,
    uint256 value_
  ) internal virtual {
    // Minting is a special case for which we should not check the balance of
    // the sender, and we should increase the total supply.
    // 발행은 발신자의 잔액을 확인해서는 안되는 특별한 경우이므로 총 공급량을 늘려야 한다.
    if (from_ == address(0)) {
      totalSupply += value_;
    } else {
      // Deduct value from sender's balance.
      // 발신자의 잔액에서 값을 차감
      balanceOf[from_] -= value_;
    }

    // Update the recipient's balance.
    // Can be unchecked because on mint, adding to totalSupply is checked, and on transfer balance deduction is checked.
    // 수신자의 잔액을 업데이트
    // totalSupply에 추가가 확인되고, 전송 시 잔액 차감이 확인되었으므로 unchecked를 사용할 수 있다.
    unchecked {
      balanceOf[to_] += value_;
    }

    emit ERC20Transfer(from_, to_, value_);
  }

  /// @notice Consolidated record keeping function for transferring ERC-721s.
  /// @dev Assign the token to the new owner, and remove from the old owner.
  /// Note that this function allows transfers to and from 0x0.
  /// Does not handle ERC-721 exemptions.
  /// ERC-721 전송을 위한 통합 기록 보관 함수
  /// 토큰을 새 소유자에게 할당하고 이전 소유자에서 제거한다.
  /// 참고: 이 함수는 0x0으로 전송을 허용한다.
  /// ERC-721 면제를 처리하지 않는다.
  function _transferERC721(
    address from_,
    address to_,
    uint256 id_
  ) internal virtual {
    // If this is not a mint, handle record keeping for transfer from previous owner.
    // 이것이 mint가 아닌 경우 이전 소유자로부터의 전송에 대한 기록 유지를 처리한다.
    if (from_ != address(0)) {
      // On transfer of an NFT, any previous approval is reset.
      // NFT 전송하면 이전 승인이 재설정된다.
      delete getApproved[id_];

      uint256 updatedId = _owned[from_][_owned[from_].length - 1];
      if (updatedId != id_) {
        uint256 updatedIndex = _getOwnedIndex(id_);
        // update _owned for sender
        // 발신자의 _owned를 업데이트
        _owned[from_][updatedIndex] = updatedId;
        // update index for the moved id
        // 이동된 id의 인덱스를 업데이트
        _setOwnedIndex(updatedId, updatedIndex);
      }

      // pop
      _owned[from_].pop();
    }

    // Check if this is a burn.
    // 이것이 소각인지 확인
    if (to_ != address(0)) {
      // If not a burn, update the owner of the token to the new owner.
      // Update owner of the token to the new owner.
      // 소각이 아니라면, 토큰 소유자를 새 소유자로 업데이트
      _setOwnerOf(id_, to_);
      // Push token onto the new owner's stack.
      // 새 소유자 스택에 토큰을 푸시
      _owned[to_].push(id_);
      // Update index for new owner's stack.
      // 새 소유자 스택의 인덱스를 업데이트
      _setOwnedIndex(id_, _owned[to_].length - 1);
    } else {
      // If this is a burn, reset the owner of the token to 0x0 by deleting the token from _ownedData.
      // 소각인 경우 _ownedData에서 토큰을 삭제하여 토큰 소유자를 0x0으로 재설정
      delete _ownedData[id_];
    }

    emit ERC721Transfer(from_, to_, id_);
  }

  /// @notice Internal function for ERC-20 transfers. Also handles any ERC-721 transfers that may be required.
  // Handles ERC-721 exemptions.
  /// ERC-20 전송을 위한 내부 함수. 또한 필요할 수 있는 ERC-721전송도 처리한다.
  // ERC-721 예외를 처리
  function _transferERC20WithERC721(
    address from_,
    address to_,
    uint256 value_
  ) internal virtual returns (bool) {
    uint256 erc20BalanceOfSenderBefore = erc20BalanceOf(from_);
    uint256 erc20BalanceOfReceiverBefore = erc20BalanceOf(to_);

    _transferERC20(from_, to_, value_);

    // Preload for gas savings on branches
    // 가스 절약을 위해 분기에 대한 사전 로드
    bool isFromERC721TransferExempt = erc721TransferExempt[from_];
    bool isToERC721TransferExempt = erc721TransferExempt[to_];

    // Skip _withdrawAndStoreERC721 and/or _retrieveOrMintERC721 for ERC-721 transfer exempt addresses
    // 1) to save gas
    // 2) because ERC-721 transfer exempt addresses won't always have/need ERC-721s corresponding to their ERC20s.
    // ERC-721 전송 면제 주소의 경우 _withdrawAndStoreERC721 및/또는 _retrieveOrMintERC721을 건너뛴다.
    // 1) 가스를 절약하기 위해
    // 2) ERC721 전송 면제 주소는 항상 해당 ERC-20에 해당하는 ERC-721이 있거나 필요하지 않을 수 있다.
    if (isFromERC721TransferExempt && isToERC721TransferExempt) {
      // Case 1) Both sender and recipient are ERC-721 transfer exempt. No ERC-721s need to be transferred.
      // NOOP.
      // Case 1) 발신자와 수신자 모두 ERC-721 전송에서 면제된다. 전송할 ERC-721이 필요하지 않다.
    } else if (isFromERC721TransferExempt) {
      // Case 2) The sender is ERC-721 transfer exempt, but the recipient is not. Contract should not attempt
      //         to transfer ERC-721s from the sender, but the recipient should receive ERC-721s
      //         from the bank/minted for any whole number increase in their balance.
      // Only cares about whole number increments.
      // Case 2) 발신자는 ERC-721 전송에서 면제되지만, 수신자는 면제되지 않는다. 
      //         계약은 발신자로부터 ERC-721을 전송하려고 시도해서는 안되지만, 수신자는 잔액의 증가에 대해 은행에서 발행된 ERC-721을 받아야한다.
      // 정수 증분만 고려한다.
      uint256 tokensToRetrieveOrMint = (balanceOf[to_] / units) -
        (erc20BalanceOfReceiverBefore / units);
      for (uint256 i = 0; i < tokensToRetrieveOrMint;) {
        _retrieveOrMintERC721(to_);
        unchecked {
          i++;
        }
      }
    } else if (isToERC721TransferExempt) {
      // Case 3) The sender is not ERC-721 transfer exempt, but the recipient is. Contract should attempt
      //         to withdraw and store ERC-721s from the sender, but the recipient should not
      //         receive ERC-721s from the bank/minted.
      // Only cares about whole number increments.
      // Case 3) 발신자는 ERC-721 전송에서 면제되지만, 수신자는 면제되지 않는다. 
      //         계약은 발신자로부터 ERC-721을 인출하고 저장하려고 시도해야 하지만, 수신자는 은행에서 발행된 ERC-721을 받지 않아야 한다.
      // 정수 증분만 고려한다.
      uint256 tokensToWithdrawAndStore = (erc20BalanceOfSenderBefore / units) -
        (balanceOf[from_] / units);
      for (uint256 i = 0; i < tokensToWithdrawAndStore;) {
        _withdrawAndStoreERC721(from_);
        unchecked {
          i++;
        }
      }
    } else {
      // Case 4) Neither the sender nor the recipient are ERC-721 transfer exempt.
      // Strategy:
      // 1. First deal with the whole tokens. These are easy and will just be transferred.
      // 2. Look at the fractional part of the value:
      //   a) If it causes the sender to lose a whole token that was represented by an NFT due to a
      //      fractional part being transferred, withdraw and store an additional NFT from the sender.
      //   b) If it causes the receiver to gain a whole new token that should be represented by an NFT
      //      due to receiving a fractional part that completes a whole token, retrieve or mint an NFT to the recevier.

      // Whole tokens worth of ERC-20s get transferred as ERC-721s without any burning/minting.

      // Case 4) 발신자와 수신자 모두 ERC-721 전송에서 면제되지 않는다.
      // 전략:
      // 1. 먼저 전체 토큰을 처리한다. 이들은 쉽게 전송될 것이다.
      // 2. 값의 분수 부분을 살펴본다.
      //    a) 발신자가 분수 부분을 전송함으로써 NFT로 표시되었던 완전한 토큰을 잃게 되면, 발신자로부터 추가 NFT를 인출하여 저장한다.
      //    b) 수신자가 분수 부분을 받아 완전한 새로운 토큰을 NFT로 표현해야 하는 경우, 수신자에게 NFT를 검색하거나 발행한다.

      // ERC-20의 완전한 토큰 가치는 소각/발행 없이 ERC-721로 전송된다.
      uint256 nftsToTransfer = value_ / units;
      for (uint256 i = 0; i < nftsToTransfer;) {
        // Pop from sender's ERC-721 stack and transfer them (LIFO)
        // 발신자의 ERC-721 스택에서 Pop하고 이들을 전송한다.
        uint256 indexOfLastToken = _owned[from_].length - 1;
        uint256 tokenId = _owned[from_][indexOfLastToken];
        _transferERC721(from_, to_, tokenId);
        unchecked {
          i++;
        }
      }

      // If the sender's transaction changes their holding from a fractional to a non-fractional
      // amount (or vice versa), adjust ERC-721s.
      //
      // Check if the send causes the sender to lose a whole token that was represented by an ERC-721
      // due to a fractional part being transferred.
      //
      // To check this, look if subtracting the fractional amount from the balance causes the balance to
      // drop below the original balance % units, which represents the number of whole tokens they started with.
      // 발신자의 거래로 인해 보유 금액이 분수에서 비분수 금액으로(또는 그 반대로) 변경되면 ERC-721을 조정한다.
      // 전송으로 인해 발신자가 소수 부분 전송으로 인해 ERC-721로 표시되는 완전한 토큰을 잃게 되는지 확인한다.
      // 이를 확인하려면 잔액에서 분수 금액을 빼면 잔액이 원래 잔액 % 단위 아래로 떨어지는지 확인한다.
      // 이는 처음에 시작한 완전한 토큰의 수를 나타낸다.
      uint256 fractionalAmount = value_ % units;

      if (
        (erc20BalanceOfSenderBefore - fractionalAmount) / units <
        (erc20BalanceOfSenderBefore / units)
      ) {
        _withdrawAndStoreERC721(from_);
      }

      // Check if the receive causes the receiver to gain a whole new token that should be represented
      // by an NFT due to receiving a fractional part that completes a whole token.
      // 수신자가 토큰을 완성하는 분수 부분을 수신하여 NFT로 표시되어야 하는 완전히 새로운 토큰을 얻게 되는지 확인한다.
      if (
        (erc20BalanceOfReceiverBefore + fractionalAmount) / units >
        (erc20BalanceOfReceiverBefore / units)
      ) {
        _retrieveOrMintERC721(to_);
      }
    }

    return true;
  }

  /// @notice Internal function for ERC20 minting
  /// @dev This function will allow minting of new ERC20s.
  ///      If mintCorrespondingERC721s_ is true, and the recipient is not ERC-721 exempt, it will also mint the corresponding ERC721s.
  /// Handles ERC-721 exemptions.
  /// ERC20 발행을 위한 내부 함수
  /// 이 함수를 사용하면 새로운 ERC20을 만들 수 있다.
  /// mintCorrespondingERC721s_가 true이고 수신자가 ERC-721 면제 대상이 아닌 경우 해당 ERC721도 발행된다.
  /// ERC-721 면제를 처리한다.
  function _mintERC20(
    address to_,
    uint256 value_,
    bool mintCorrespondingERC721s_
  ) internal virtual {
    /// You cannot mint to the zero address (you can't mint and immediately burn in the same transfer).
    /// 0 주소로 발행할 수 없다.(동일한 전송에서 발행과 즉시 소각을 할 수 없다. )
    if (to_ == address(0)) {
      revert InvalidRecipient();
    }

    _transferERC20(address(0), to_, value_);

    // If mintCorrespondingERC721s_ is true, and the recipient is not ERC-721 transfer exempt, mint the corresponding ERC721s.
    // mintCorrespondingERC721s_가 true이고 수신자가 ERC-721 전송 면제 대상이 아닌 경우 해당 ERC721을 발행한다.
    if (mintCorrespondingERC721s_ && !erc721TransferExempt[to_]) {
      uint256 nftsToRetrieveOrMint = value_ / units;
      for (uint256 i = 0; i < nftsToRetrieveOrMint;) {
        // ERC-721 exemptions handled above.
        // 위에서 처리된 ERC-721 면제
        _retrieveOrMintERC721(to_);
        unchecked {
          i++;
        }
      }
    }
  }

  /// @notice Internal function for ERC-721 minting and retrieval from the bank.
  /// @dev This function will allow minting of new ERC-721s up to the total fractional supply. It will
  ///      first try to pull from the bank, and if the bank is empty, it will mint a new token.
  /// Does not handle ERC-721 exemptions.
  /// 은행에서 ERC-721을 회수하거나 새로 발행하는 내부 함수
  /// 이 함수는 총 분할 공급량을 초과하지 않는 한 새로운 ERC-721을 발행할 수 있다.
  /// 먼저 은행에서 토큰을 회수하려고 시도하고, 은행이 비어 있으면 새 토큰을 발행한다.
  /// ERC-721 면제를 처리하지 않는다.
  function _retrieveOrMintERC721(address to_) internal virtual {
    if (to_ == address(0)) {
      revert InvalidRecipient();
    }

    uint256 id;

    if (!DoubleEndedQueue.empty(_storedERC721Ids)) {
      // If there are any tokens in the bank, use those first.
      // Pop off the end of the queue (FIFO).
      // 은행에서 토큰이 있으면 먼저 토큰을 사용한다.
      // 대기열의 끝 부분을 Pop한다.
      id = _storedERC721Ids.popBack();
    } else {
      // Otherwise, mint a new token, should not be able to go over the total fractional supply.
      // 그렇지 않으면 새 토큰을 발행하여 전체 부분 공급량을 초과할 수 없어야 한다.
      _minted++;
      id = _minted;
    }

    address erc721Owner = _getOwnerOf(id);

    // The token should not already belong to anyone besides 0x0 or this contract.
    // If it does, something is wrong, as this should never happen.
    // 토큰은 0x0 또는 이 계약 이외의 누구에게도 속해 있어서는 안된다.
    // 만약 그렇다면, 이런 일이 일어나서는 안되기 때문에 뭔가 잘못된 것이다.
    if (erc721Owner != address(0)) {
      revert AlreadyExists();
    }

    // Transfer the token to the recipient, either transferring from the contract's bank or minting.
    // Does not handle ERC-721 exemptions.
    // 계약의 은행에서 이체하거나 발행하여 토큰을 수신자에게 전송한다.
    // ERC-721 면제를 처리하지 않는다.
    _transferERC721(erc721Owner, to_, id);
  }

  /// @notice Internal function for ERC-721 deposits to bank (this contract).
  /// @dev This function will allow depositing of ERC-721s to the bank, which can be retrieved by future minters.
  // Does not handle ERC-721 exemptions.
  /// ERC-721을 은행에 입금하기위한 내부함수
  /// 이 함수를 사용하면 ERC-721을 은행에 입금할 수 있으며, 이는 향후 발행자가 회수할 수 있다.
  // ERC-721 면제를 처리하지 않는다.
  function _withdrawAndStoreERC721(address from_) internal virtual {
    if (from_ == address(0)) {
      revert InvalidSender();
    }

    // Retrieve the latest token added to the owner's stack (LIFO).
    // 소유자 스택에 추가된 최신 토큰을 찾는다.
    uint256 id = _owned[from_][_owned[from_].length - 1];

    // Transfer to 0x0.
    // Does not handle ERC-721 exemptions.
    // 0x0으로 전송한다.
    // ERC-721 면제를 처리하지 않는다.
    _transferERC721(from_, address(0), id);

    // Record the token in the contract's bank queue.
    // 게약의 은행 대기열에 토큰을 기록한다.
    _storedERC721Ids.pushFront(id);
  }

  /// @notice Initialization function to set pairs / etc, saving gas by avoiding mint / burn on unnecessary targets
  /// 초기화 함수로서, 페어 설정 등을 하며 불필요한 목표에 대한 발행/소각을 피함으로써 가스를 절약한다.
  function _setERC721TransferExempt(address target_, bool state_) internal virtual {
    // If the target has at least 1 full ERC-20 token, they should not be removed from the exempt list
    // because if they were and then they attempted to transfer, it would revert as they would not
    // necessarily have ehough ERC-721s to bank.
    // 대상에 완전한 ERC-20토큰이 1개 이상 있는 경우 면제 목록에서 제거해서는 안된다.
    // 왜냐하면 전송을 시도한 경우 은행에 ERC-721이 충분하지 않아서 실패할 수 있기 때문이다.
    if (erc20BalanceOf(target_) >= units && !state_) {
      revert CannotRemoveFromERC721TransferExempt();
    }

    erc721TransferExempt[target_] = state_;
  }
  /// 주어진 ID의 소유자를 조회하는 내부 함수
  function _getOwnerOf(
    uint256 id_
  ) internal view virtual returns (address ownerOf_) {
    uint256 data = _ownedData[id_];

    assembly {
      // 데이터에서 주소 부분만 추출한다.
      ownerOf_ := and(data, _BITMASK_ADDRESS)
    }
  }

  /// 주어진 ID의 소유자를 설정하는 내부 함수
  function _setOwnerOf(uint256 id_, address owner_) internal virtual {
    uint256 data = _ownedData[id_];

    assembly {
      data := add(
        and(data, _BITMASK_OWNED_INDEX),    // 기존 인덱스를 유지한다.
        and(owner_, _BITMASK_ADDRESS)   // 새 소유자 주소를 설정한다.
      )
    }

    _ownedData[id_] = data;
  }

  /// 주어진 ID의 소유된 인덱스를 조회하는 내부 함수
  function _getOwnedIndex(
    uint256 id_
  ) internal view virtual returns (uint256 ownedIndex_) {
    uint256 data = _ownedData[id_];

    assembly {
      ownedIndex_ := shr(160, data)  // 데이터에서 인덱스 부분만 추출한다.
    }
  }

  /// 주어진 ID의 소유된 인덱스를 설정하는 내부 함수
  function _setOwnedIndex(uint256 id_, uint256 index_) internal virtual {
    uint256 data = _ownedData[id_];

    if (index_ > _BITMASK_OWNED_INDEX >> 160) {
      revert OwnedIndexOverflow();
    }

    assembly {
      data := add(
        and(data, _BITMASK_ADDRESS),    // 기존 주소를 유지한다.
        and(shl(160, index_), _BITMASK_OWNED_INDEX) // 새 인덱스를 설정한다.
      )
    }

    _ownedData[id_] = data;
  }
}