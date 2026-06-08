// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TrustTicket is ERC721Enumerable, AccessControl, ReentrancyGuard {
    bytes32 public constant ORGANIZER_ROLE = keccak256("ORGANIZER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

    uint256 public constant RESALE_RATE_DENOMINATOR = 10_000;

    struct EventInfo {
        uint256 eventId;
        address organizer;
        string eventName;
        uint256 eventTimestamp;
        uint256 ticketPrice;
        uint256 totalTicketCount;
        uint256 remainingTicketCount;
        uint256 primarySaleStart;
        uint256 primarySaleEnd;
        bool resaleAllowed;
        uint256 maxResalePriceRate;
        uint256 resaleStart;
        uint256 resaleEnd;
        bool active;
        bool canceled;
    }

    struct TicketInfo {
        uint256 tokenId;
        uint256 eventId;
        string seatInfo;
        uint256 originalPrice;
        bool used;
        bool listed;
    }

    struct ListingInfo {
        uint256 tokenId;
        address seller;
        uint256 price;
        bool active;
    }

    struct MembershipPolicy {
        bool enabled;
        address membershipToken;
        uint256 memberPrice;
        uint256 memberPresaleStart;
        uint256 memberPresaleEnd;
        bool publicSaleDiscount;
    }

    struct EscrowPayment {
        address payer;
        address payee;
        uint256 amount;
        bool refunded;
        bool withdrawn;
    }

    error NotOrganizer();
    error NotEventOrganizer();
    error NotValidator();
    error InvalidAddress();
    error InvalidEvent();
    error InvalidSaleWindow();
    error InvalidTicketSupply();
    error InvalidPrice();
    error EventInactive();
    error PrimarySaleClosed();
    error ResaleClosed();
    error ResaleNotAllowed();
    error TicketUnavailable();
    error TicketUsedError();
    error TicketListedError();
    error TicketNotListed();
    error NotTicketOwner();
    error SelfPurchase();
    error PriceCapExceeded();
    error PaymentTransferFailed();
    error PurchaseNotEligible();
    error EventCanceled();
    error EventNotCanceled();
    error NoEscrowBalance();
    error EscrowAlreadyWithdrawn();
    error EscrowAlreadyRefunded();
    error MembershipPassRequired();
    error InvalidMembershipPolicy();
    error InvalidMembershipToken();
    error SettlementNotAvailable();
    error TicketTransferRestricted();

    uint256 private _nextEventId = 1;
    uint256 private _nextTokenId = 1;
    bool private _marketplaceTransfer;

    mapping(uint256 => EventInfo) private _events;
    mapping(uint256 => TicketInfo) private _tickets;
    mapping(uint256 => ListingInfo) private _listings;
    mapping(uint256 => MembershipPolicy) private _membershipPolicies;
    mapping(uint256 => uint256[]) private _eventTickets;
    mapping(uint256 => mapping(address => bool)) private _eventValidators;
    mapping(uint256 => EscrowPayment) private _primaryPayments;
    mapping(uint256 => EscrowPayment) private _resalePayments;
    mapping(uint256 => uint256) private _eventEscrowBalances;
    mapping(address => uint256) private _resaleEscrowBalances;
    mapping(uint256 => bool) private _eventRevenueWithdrawn;

    event OrganizerAdded(address indexed organizer);
    event ValidatorAdded(address indexed validator, uint256 indexed eventId);
    event MembershipPolicyUpdated(
        uint256 indexed eventId,
        address indexed membershipToken,
        bool enabled,
        uint256 memberPrice
    );
    event EventCreated(uint256 indexed eventId, address indexed organizer, string eventName);
    event TicketMinted(uint256 indexed eventId, uint256 indexed tokenId, string seatInfo);
    event TicketBurned(uint256 indexed eventId, uint256 indexed tokenId);
    event TicketPurchased(uint256 indexed eventId, uint256 indexed tokenId, address indexed buyer, uint256 price);
    event TicketListed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event TicketListingCanceled(uint256 indexed tokenId, address indexed seller);
    event TicketResold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price);
    event TicketUsed(uint256 indexed tokenId, uint256 indexed eventId, address indexed validator);
    event EventStatusChanged(uint256 indexed eventId, bool active);
    event EventCancellationRecorded(uint256 indexed eventId);
    event EventRevenueWithdrawn(uint256 indexed eventId, address indexed organizer, uint256 amount);
    event ResaleRevenueWithdrawn(uint256 indexed tokenId, address indexed seller, uint256 amount);
    event TicketRefunded(uint256 indexed tokenId, address indexed buyer, uint256 amount);

    constructor(address admin) ERC721("TRUST-TICKET", "TRUST") {
        if (admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function addOrganizer(address organizer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (organizer == address(0)) revert InvalidAddress();
        _grantRole(ORGANIZER_ROLE, organizer);
        emit OrganizerAdded(organizer);
    }

    function addValidator(address validator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (validator == address(0)) revert InvalidAddress();
        _grantRole(VALIDATOR_ROLE, validator);
        emit ValidatorAdded(validator, 0);
    }

    function addEventValidator(uint256 eventId, address validator) external {
        if (validator == address(0)) revert InvalidAddress();
        EventInfo storage eventInfo = _requireEvent(eventId);
        if (msg.sender != eventInfo.organizer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotEventOrganizer();
        }

        _eventValidators[eventId][validator] = true;
        emit ValidatorAdded(validator, eventId);
    }

    function createEvent(
        string calldata eventName,
        uint256 eventTimestamp,
        uint256 ticketPrice,
        uint256 totalTicketCount,
        uint256 primarySaleStart,
        uint256 primarySaleEnd,
        bool resaleAllowed,
        uint256 maxResalePriceRate,
        uint256 resaleStart,
        uint256 resaleEnd
    ) external onlyRole(ORGANIZER_ROLE) returns (uint256 eventId) {
        if (ticketPrice == 0) revert InvalidPrice();
        if (totalTicketCount == 0) revert InvalidTicketSupply();
        if (primarySaleStart >= primarySaleEnd) revert InvalidSaleWindow();
        if (resaleAllowed) {
            if (resaleStart >= resaleEnd) revert InvalidSaleWindow();
            if (maxResalePriceRate < RESALE_RATE_DENOMINATOR) revert InvalidPrice();
        }

        eventId = _nextEventId++;
        _events[eventId] = EventInfo({
            eventId: eventId,
            organizer: msg.sender,
            eventName: eventName,
            eventTimestamp: eventTimestamp,
            ticketPrice: ticketPrice,
            totalTicketCount: totalTicketCount,
            remainingTicketCount: totalTicketCount,
            primarySaleStart: primarySaleStart,
            primarySaleEnd: primarySaleEnd,
            resaleAllowed: resaleAllowed,
            maxResalePriceRate: maxResalePriceRate,
            resaleStart: resaleStart,
            resaleEnd: resaleEnd,
            active: true,
            canceled: false
        });

        emit EventCreated(eventId, msg.sender, eventName);
    }

    function setMembershipPolicy(
        uint256 eventId,
        bool enabled,
        address membershipToken,
        uint256 memberPrice,
        uint256 memberPresaleStart,
        uint256 memberPresaleEnd,
        bool publicSaleDiscount
    ) external {
        EventInfo storage eventInfo = _requireEvent(eventId);
        if (msg.sender != eventInfo.organizer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotEventOrganizer();
        }
        if (enabled) {
            if (!_isErc721Contract(membershipToken)) revert InvalidMembershipToken();
            if (memberPrice == 0 || memberPrice > eventInfo.ticketPrice) revert InvalidMembershipPolicy();
            if (memberPresaleStart >= memberPresaleEnd) revert InvalidSaleWindow();
        }

        _membershipPolicies[eventId] = MembershipPolicy({
            enabled: enabled,
            membershipToken: membershipToken,
            memberPrice: memberPrice,
            memberPresaleStart: memberPresaleStart,
            memberPresaleEnd: memberPresaleEnd,
            publicSaleDiscount: publicSaleDiscount
        });

        emit MembershipPolicyUpdated(eventId, membershipToken, enabled, memberPrice);
    }

    function setEventStatus(uint256 eventId, bool active) external {
        EventInfo storage eventInfo = _requireEvent(eventId);
        if (msg.sender != eventInfo.organizer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotEventOrganizer();
        }
        eventInfo.active = active;
        emit EventStatusChanged(eventId, active);
    }

    function cancelEvent(uint256 eventId) external {
        EventInfo storage eventInfo = _requireEvent(eventId);
        if (msg.sender != eventInfo.organizer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotEventOrganizer();
        }
        eventInfo.active = false;
        eventInfo.canceled = true;
        emit EventStatusChanged(eventId, false);
        emit EventCancellationRecorded(eventId);
    }

    function mintTicket(uint256 eventId, string calldata seatInfo) external returns (uint256 tokenId) {
        EventInfo storage eventInfo = _requireEvent(eventId);
        if (msg.sender != eventInfo.organizer) revert NotEventOrganizer();
        if (_eventTickets[eventId].length >= eventInfo.totalTicketCount) revert InvalidTicketSupply();

        tokenId = _nextTokenId++;
        _tickets[tokenId] = TicketInfo({
            tokenId: tokenId,
            eventId: eventId,
            seatInfo: seatInfo,
            originalPrice: eventInfo.ticketPrice,
            used: false,
            listed: false
        });
        _eventTickets[eventId].push(tokenId);
        _mint(address(this), tokenId);

        emit TicketMinted(eventId, tokenId, seatInfo);
    }

    function burnUnissuedTicket(uint256 tokenId) external {
        TicketInfo storage ticket = _requireTicket(tokenId);
        EventInfo storage eventInfo = _requireEvent(ticket.eventId);

        if (msg.sender != eventInfo.organizer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotEventOrganizer();
        }
        if (ownerOf(tokenId) != address(this)) revert TicketUnavailable();
        if (ticket.used) revert TicketUsedError();
        if (ticket.listed) revert TicketListedError();
        if (eventInfo.remainingTicketCount == 0 || eventInfo.totalTicketCount == 0) revert InvalidTicketSupply();

        uint256 eventId = ticket.eventId;
        eventInfo.remainingTicketCount -= 1;
        eventInfo.totalTicketCount -= 1;
        _removeEventTicket(eventId, tokenId);
        delete _tickets[tokenId];
        _burn(tokenId);

        emit TicketBurned(eventId, tokenId);
    }

    function purchaseTicket(uint256 tokenId) external payable nonReentrant {
        TicketInfo storage ticket = _requireTicket(tokenId);
        EventInfo storage eventInfo = _requireEvent(ticket.eventId);

        if (!eventInfo.active) revert EventInactive();
        if (eventInfo.canceled) revert EventCanceled();
        uint256 requiredPrice = _purchasePrice(msg.sender, eventInfo);
        if (msg.value != requiredPrice) revert InvalidPrice();
        if (!_checkPurchaseEligibility(msg.sender, ticket.eventId)) revert PurchaseNotEligible();
        if (ticket.used) revert TicketUsedError();
        if (ticket.listed) revert TicketListedError();
        if (ownerOf(tokenId) != address(this)) revert TicketUnavailable();
        if (eventInfo.remainingTicketCount == 0) revert TicketUnavailable();

        eventInfo.remainingTicketCount -= 1;
        _eventEscrowBalances[ticket.eventId] += msg.value;
        _primaryPayments[tokenId] = EscrowPayment({
            payer: msg.sender,
            payee: eventInfo.organizer,
            amount: msg.value,
            refunded: false,
            withdrawn: false
        });
        _safeTransfer(address(this), msg.sender, tokenId, "");

        emit TicketPurchased(ticket.eventId, tokenId, msg.sender, msg.value);
    }

    function listTicket(uint256 tokenId, uint256 resalePrice) external {
        TicketInfo storage ticket = _requireTicket(tokenId);
        EventInfo storage eventInfo = _requireEvent(ticket.eventId);

        if (ownerOf(tokenId) != msg.sender) revert NotTicketOwner();
        if (!eventInfo.active) revert EventInactive();
        if (eventInfo.canceled) revert EventCanceled();
        if (ticket.used) revert TicketUsedError();
        if (ticket.listed) revert TicketListedError();
        if (!eventInfo.resaleAllowed) revert ResaleNotAllowed();
        if (block.timestamp < eventInfo.resaleStart || block.timestamp > eventInfo.resaleEnd) revert ResaleClosed();
        if (resalePrice == 0) revert InvalidPrice();

        uint256 maxPrice = (ticket.originalPrice * eventInfo.maxResalePriceRate) / RESALE_RATE_DENOMINATOR;
        if (resalePrice > maxPrice) revert PriceCapExceeded();

        ticket.listed = true;
        _listings[tokenId] = ListingInfo({tokenId: tokenId, seller: msg.sender, price: resalePrice, active: true});

        emit TicketListed(tokenId, msg.sender, resalePrice);
    }

    function cancelListing(uint256 tokenId) external {
        TicketInfo storage ticket = _requireTicket(tokenId);
        ListingInfo storage listing = _listings[tokenId];

        if (!ticket.listed || !listing.active) revert TicketNotListed();
        if (ownerOf(tokenId) != msg.sender) revert NotTicketOwner();

        address seller = listing.seller;
        ticket.listed = false;
        delete _listings[tokenId];

        emit TicketListingCanceled(tokenId, seller);
    }

    function purchaseResaleTicket(uint256 tokenId) external payable nonReentrant {
        TicketInfo storage ticket = _requireTicket(tokenId);
        EventInfo storage eventInfo = _requireEvent(ticket.eventId);
        ListingInfo memory listing = _listings[tokenId];

        if (!eventInfo.active) revert EventInactive();
        if (eventInfo.canceled) revert EventCanceled();
        if (ticket.used) revert TicketUsedError();
        if (!ticket.listed || !listing.active) revert TicketNotListed();
        if (block.timestamp < eventInfo.resaleStart || block.timestamp > eventInfo.resaleEnd) revert ResaleClosed();
        if (msg.sender == listing.seller) revert SelfPurchase();
        if (msg.value != listing.price) revert InvalidPrice();
        if (!_checkPurchaseEligibility(msg.sender, ticket.eventId)) revert PurchaseNotEligible();
        if (ownerOf(tokenId) != listing.seller) revert TicketUnavailable();

        ticket.listed = false;
        delete _listings[tokenId];
        _resaleEscrowBalances[listing.seller] += msg.value;
        _resalePayments[tokenId] = EscrowPayment({
            payer: msg.sender,
            payee: listing.seller,
            amount: msg.value,
            refunded: false,
            withdrawn: false
        });

        _marketplaceTransfer = true;
        _safeTransfer(listing.seller, msg.sender, tokenId, "");
        _marketplaceTransfer = false;

        emit TicketResold(tokenId, listing.seller, msg.sender, msg.value);
    }

    function withdrawEventRevenue(uint256 eventId) external nonReentrant {
        EventInfo storage eventInfo = _requireEvent(eventId);
        if (msg.sender != eventInfo.organizer) revert NotEventOrganizer();
        if (eventInfo.canceled) revert EventCanceled();
        if (block.timestamp < eventInfo.eventTimestamp) revert SettlementNotAvailable();
        if (_eventRevenueWithdrawn[eventId]) revert EscrowAlreadyWithdrawn();
        uint256 amount = _eventEscrowBalances[eventId];
        if (amount == 0) revert NoEscrowBalance();

        _eventRevenueWithdrawn[eventId] = true;
        _eventEscrowBalances[eventId] = 0;

        (bool paid, ) = msg.sender.call{value: amount}("");
        if (!paid) revert PaymentTransferFailed();

        emit EventRevenueWithdrawn(eventId, msg.sender, amount);
    }

    function withdrawResaleRevenue(uint256 tokenId) external nonReentrant {
        TicketInfo storage ticket = _requireTicket(tokenId);
        EventInfo storage eventInfo = _requireEvent(ticket.eventId);
        EscrowPayment storage payment = _resalePayments[tokenId];

        if (eventInfo.canceled) revert EventCanceled();
        if (block.timestamp < eventInfo.eventTimestamp) revert SettlementNotAvailable();
        if (payment.payee != msg.sender) revert NotTicketOwner();
        if (payment.withdrawn) revert EscrowAlreadyWithdrawn();
        if (payment.refunded) revert EscrowAlreadyRefunded();
        uint256 amount = payment.amount;
        if (amount == 0) revert NoEscrowBalance();
        if (_resaleEscrowBalances[msg.sender] < amount) revert NoEscrowBalance();

        payment.withdrawn = true;
        _resaleEscrowBalances[msg.sender] -= amount;

        (bool paid, ) = msg.sender.call{value: amount}("");
        if (!paid) revert PaymentTransferFailed();

        emit ResaleRevenueWithdrawn(tokenId, msg.sender, amount);
    }

    function refundTicket(uint256 tokenId) external nonReentrant {
        TicketInfo storage ticket = _requireTicket(tokenId);
        EventInfo storage eventInfo = _requireEvent(ticket.eventId);
        if (!eventInfo.canceled) revert EventNotCanceled();
        if (ownerOf(tokenId) != msg.sender) revert NotTicketOwner();

        (address resaleRefundTo, uint256 resaleRefundAmount) = _refundResaleIfPossible(tokenId);
        (address primaryRefundTo, uint256 primaryRefundAmount) = _refundPrimaryIfPossible(tokenId, ticket.eventId);
        if (resaleRefundAmount == 0 && primaryRefundAmount == 0) revert NoEscrowBalance();

        ticket.used = true;
        if (ticket.listed) {
            address seller = _listings[tokenId].seller;
            ticket.listed = false;
            delete _listings[tokenId];
            emit TicketListingCanceled(tokenId, seller);
        }

        if (resaleRefundAmount > 0) {
            _payRefund(tokenId, resaleRefundTo, resaleRefundAmount);
        }
        if (primaryRefundAmount > 0) {
            _payRefund(tokenId, primaryRefundTo, primaryRefundAmount);
        }
    }

    function useTicket(uint256 tokenId) external {
        TicketInfo storage ticket = _requireTicket(tokenId);
        if (!_isValidatorForEvent(ticket.eventId, msg.sender)) revert NotValidator();
        if (ticket.used) revert TicketUsedError();
        if (ownerOf(tokenId) == address(this)) revert TicketUnavailable();

        if (ticket.listed) {
            address seller = _listings[tokenId].seller;
            ticket.listed = false;
            delete _listings[tokenId];
            emit TicketListingCanceled(tokenId, seller);
        }

        ticket.used = true;
        emit TicketUsed(tokenId, ticket.eventId, msg.sender);
    }

    function getEventInfo(uint256 eventId) external view returns (EventInfo memory) {
        return _requireEventView(eventId);
    }

    function getTicketInfo(uint256 tokenId) external view returns (TicketInfo memory) {
        return _requireTicketView(tokenId);
    }

    function getListingInfo(uint256 tokenId) external view returns (ListingInfo memory) {
        _requireTicketView(tokenId);
        return _listings[tokenId];
    }

    function getMembershipPolicy(uint256 eventId) external view returns (MembershipPolicy memory) {
        _requireEventView(eventId);
        return _membershipPolicies[eventId];
    }

    function hasMembershipPass(uint256 eventId, address account) external view returns (bool) {
        if (account == address(0)) revert InvalidAddress();
        MembershipPolicy memory policy = _membershipPolicies[eventId];
        if (!policy.enabled) return false;
        return _hasMembership(policy.membershipToken, account);
    }

    function getEventEscrowBalance(uint256 eventId) external view returns (uint256) {
        _requireEventView(eventId);
        return _eventEscrowBalances[eventId];
    }

    function getResaleEscrowBalance(address seller) external view returns (uint256) {
        if (seller == address(0)) revert InvalidAddress();
        return _resaleEscrowBalances[seller];
    }

    function getTicketsByEvent(uint256 eventId) external view returns (uint256[] memory) {
        _requireEventView(eventId);
        return _eventTickets[eventId];
    }

    function getTicketsByOwner(address owner) external view returns (uint256[] memory tokenIds) {
        if (owner == address(0)) revert InvalidAddress();
        uint256 balance = balanceOf(owner);
        tokenIds = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(owner, i);
        }
    }

    function isTicketValid(uint256 tokenId) external view returns (bool) {
        TicketInfo memory ticket = _requireTicketView(tokenId);
        EventInfo memory eventInfo = _requireEventView(ticket.eventId);
        return eventInfo.active && !ticket.used && ownerOf(tokenId) != address(this);
    }

    function isTicketListed(uint256 tokenId) external view returns (bool) {
        TicketInfo memory ticket = _requireTicketView(tokenId);
        return ticket.listed && _listings[tokenId].active;
    }

    function getTicketCheckInMessageHash(
        uint256 tokenId,
        address claimedOwner,
        uint256 expiresAt
    ) public view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), block.chainid, tokenId, claimedOwner, expiresAt));
    }

    function verifySignedTicket(
        uint256 tokenId,
        address claimedOwner,
        uint256 expiresAt,
        bytes calldata signature
    ) public view returns (bool) {
        if (block.timestamp > expiresAt) return false;
        if (claimedOwner == address(0)) return false;
        if (_ownerOf(tokenId) != claimedOwner) return false;
        if (!this.isTicketValid(tokenId)) return false;

        bytes32 messageHash = getTicketCheckInMessageHash(tokenId, claimedOwner, expiresAt);
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (address recovered, ECDSA.RecoverError error, ) = ECDSA.tryRecover(ethSignedMessageHash, signature);

        return error == ECDSA.RecoverError.NoError && recovered == claimedOwner;
    }

    function _checkPurchaseEligibility(address buyer, uint256 eventId) internal view virtual returns (bool) {
        buyer;
        eventId;
        return true;
    }

    function _purchasePrice(address buyer, EventInfo storage eventInfo) private view returns (uint256) {
        MembershipPolicy memory policy = _membershipPolicies[eventInfo.eventId];
        if (
            policy.enabled &&
            block.timestamp >= policy.memberPresaleStart &&
            block.timestamp <= policy.memberPresaleEnd
        ) {
            if (!_hasMembership(policy.membershipToken, buyer)) revert MembershipPassRequired();
            return policy.memberPrice;
        }

        if (block.timestamp < eventInfo.primarySaleStart || block.timestamp > eventInfo.primarySaleEnd) {
            revert PrimarySaleClosed();
        }

        if (policy.enabled && policy.publicSaleDiscount && _hasMembership(policy.membershipToken, buyer)) {
            return policy.memberPrice;
        }
        return eventInfo.ticketPrice;
    }

    function _hasMembership(address membershipToken, address account) private view returns (bool) {
        if (membershipToken == address(0)) return false;
        return IERC721(membershipToken).balanceOf(account) > 0;
    }

    function _isErc721Contract(address token) private view returns (bool) {
        if (token == address(0) || token.code.length == 0) return false;
        try IERC165(token).supportsInterface(type(IERC721).interfaceId) returns (bool supported) {
            return supported;
        } catch {
            return false;
        }
    }

    function _refundPrimaryIfPossible(uint256 tokenId, uint256 eventId) private returns (address payee, uint256 amount) {
        EscrowPayment storage payment = _primaryPayments[tokenId];
        if (payment.amount == 0 || payment.refunded) return (address(0), 0);
        if (_eventRevenueWithdrawn[eventId] || payment.withdrawn) revert EscrowAlreadyWithdrawn();
        if (_eventEscrowBalances[eventId] < payment.amount) revert EscrowAlreadyWithdrawn();

        payment.refunded = true;
        _eventEscrowBalances[eventId] -= payment.amount;
        return (payment.payer, payment.amount);
    }

    function _refundResaleIfPossible(uint256 tokenId) private returns (address payee, uint256 amount) {
        EscrowPayment storage payment = _resalePayments[tokenId];
        if (payment.amount == 0 || payment.refunded) return (address(0), 0);
        if (payment.withdrawn) revert EscrowAlreadyWithdrawn();
        if (_resaleEscrowBalances[payment.payee] < payment.amount) revert EscrowAlreadyWithdrawn();

        payment.refunded = true;
        _resaleEscrowBalances[payment.payee] -= payment.amount;
        return (payment.payer, payment.amount);
    }

    function _payRefund(uint256 tokenId, address payee, uint256 amount) private {
        (bool paid, ) = payee.call{value: amount}("");
        if (!paid) revert PaymentTransferFailed();
        emit TicketRefunded(tokenId, payee, amount);
    }

    function _removeEventTicket(uint256 eventId, uint256 tokenId) private {
        uint256[] storage tokenIds = _eventTickets[eventId];
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] == tokenId) {
                tokenIds[i] = tokenIds[tokenIds.length - 1];
                tokenIds.pop();
                return;
            }
        }
        revert TicketUnavailable();
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721Enumerable) returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && !_marketplaceTransfer) {
            if (from != address(this)) revert TicketTransferRestricted();
            TicketInfo memory ticket = _tickets[tokenId];
            if (ticket.used) revert TicketUsedError();
            if (ticket.listed) revert TicketListedError();
        }

        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _isValidatorForEvent(uint256 eventId, address validator) private view returns (bool) {
        return hasRole(VALIDATOR_ROLE, validator) || _eventValidators[eventId][validator];
    }

    function _requireEvent(uint256 eventId) private view returns (EventInfo storage eventInfo) {
        eventInfo = _events[eventId];
        if (eventInfo.eventId == 0) revert InvalidEvent();
    }

    function _requireTicket(uint256 tokenId) private view returns (TicketInfo storage ticket) {
        ticket = _tickets[tokenId];
        if (ticket.tokenId == 0) revert TicketUnavailable();
    }

    function _requireEventView(uint256 eventId) private view returns (EventInfo memory eventInfo) {
        eventInfo = _events[eventId];
        if (eventInfo.eventId == 0) revert InvalidEvent();
    }

    function _requireTicketView(uint256 tokenId) private view returns (TicketInfo memory ticket) {
        ticket = _tickets[tokenId];
        if (ticket.tokenId == 0) revert TicketUnavailable();
    }
}
