// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title KipuBankV2
 * @author Gian
 * @notice Versión mejorada del contrato KipuBank.
 * @dev Banco descentralizado con soporte multi-token, control de acceso, límites globales
 *      y conversión de valores a USD mediante oráculo Chainlink.
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract KipuBankV2 is Ownable, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =============================================================
    //  1. ROLES Y CONTROL DE ACCESO
    // =============================================================

    /// @dev Rol de administrador general: puede configurar límites y tokens (políticas del sistema).
    bytes32 public constant ADMIN_ROLE   = keccak256("ADMIN_ROLE");

    /// @dev Rol de manager: puede realizar operaciones diarias, autorizar retiros especiales, desbloquear fondos, etc.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @dev Rol de auditor: solo lectura, sin permisos de modificación.
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    /**
     * @notice Modificador para funciones reservadas a administradores o al owner.
     */
    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender) && owner() != msg.sender)
            revert Unauthorized();
        _;
    }

    /**
     * @notice Modificador para funciones reservadas a managers.
     */
    modifier onlyManager() {
        if (!hasRole(MANAGER_ROLE, msg.sender))
            revert Unauthorized();
        _;
    }

    // =============================================================
    // 2. VARIABLES GLOBALES Y CONSTANTES
    // =============================================================

    /// @dev Instancia del oráculo Chainlink (ETH/USD)
    AggregatorV3Interface public immutable priceFeed;

    /// @dev Base decimal de referencia para contabilidad en USD (ej. USDC = 6)
    uint8 public constant USD_DECIMALS = 6;

    /// @dev Límite global del banco en USD (valor máximo de depósitos totales)
    uint256 public bankCapUSD;

    /// @dev Límite máximo de retiro individual por usuario (en USD)
    uint256 public withdrawLimitUSD;

    // =============================================================
    // 3. CONTABILIDAD Y ESTRUCTURAS DE DATOS
    // =============================================================

    /**
     * @dev Mapea cada usuario y token con su balance depositado.
     * - address(0) representa Ether nativo.
     * - balances[user][token] = monto depositado.
     */
    mapping(address => mapping(address => uint256)) public balances;

    /**
     * @dev Tokens ERC-20 autorizados para operar en el banco.
     */
    mapping(address => bool) public supportedTokens;

    /**
     * @dev Suma total de depósitos expresada en USD (para controlar bankCap).
     *      Esta variable se actualizará con cada depósito y retiro.
     */
    uint256 public totalDepositsUSD;

    // =============================================================
    // 4. EVENTOS
    // =============================================================

    /// @notice Se emite cuando un usuario realiza un depósito exitoso.
    event Deposit(address indexed user, address indexed token, uint256 amount);

    /// @notice Se emite cuando un usuario realiza un retiro exitoso.
    event Withdraw(address indexed user, address indexed token, uint256 amount);

    /// @notice Se emite cuando se actualiza el límite global del banco.
    event BankCapUpdated(uint256 oldCap, uint256 newCap);

    /// @notice Se emite cuando se añade un nuevo token ERC-20 permitido.
    event SupportedTokenAdded(address token);

    /// @notice Se emite cuando un token ERC-20 es removido o deshabilitado.
    event SupportedTokenRemoved(address token);

    // OpenZeppelin ya define estas funciones
    // @notice Se emite al pausar el contrato.
    //event Paused(address by);

    // @notice Se emite al reanudar el contrato.
    //event Unpaused(address by);

    /// @notice Se emite cuando se asigna un nuevo rol a una cuenta.
    event RoleGranted(address indexed account, bytes32 role);

    /// @notice Se emite cuando se revoca un rol a una cuenta.
    event RoleRevoked(address indexed account, bytes32 role);

    /// @notice Se emite al consultar el precio del oráculo Chainlink.
    event PriceChecked(uint256 ethPrice);

    /// @notice Se emite al desplegar el contrato e indica su configuración inicial.
    event ContractInitialized(address indexed owner, address oracle, uint256 bankCapUSD, uint256 withdrawLimitUSD, address[] initialTokens);

    // =============================================================
    // 5. ERRORES PERSONALIZADOS
    // =============================================================

    /// @dev Error general por falta de permisos.
    error Unauthorized();

    /// @dev Token no soportado o inválido.
    error InvalidToken(address token);

    /// @dev Balance insuficiente para retirar el monto solicitado.
    error InsufficientBalance(address user, uint256 requested, uint256 available);

    /// @dev El depósito excede el límite global del banco.
    error BankCapExceeded(uint256 cap, uint256 attempted);

    /// @dev Monto igual a cero.
    error ZeroAmount();

    /// @dev Fallo en transferencia de fondos.
    error TransferFailed();

    /// @dev Operación no permitida durante el estado pausado.
    error ContractPaused();

// =============================================================
// 6. CONSTRUCTOR E INICIALIZACIÓN DE ROLES Y LÍMITES
// =============================================================

    /**
     * @notice Despliega el contrato con roles personalizados, oráculo y tokens iniciales.
     * @param _oracleAddress Dirección del oráculo ETH/USD de Chainlink (ej: Sepolia)
     * @param _admin Dirección que recibirá el rol ADMIN
     * @param _manager Dirección que recibirá el rol MANAGER
     * @param _auditor Dirección que recibirá el rol AUDITOR
     * @param _usdc Dirección del token USDC (ERC-20) en la red actual
     * @param _cepholia Dirección del token CE Sepolia o equivalente ERC-20
     */
    constructor(
    address _oracleAddress,
    address _admin,
    address _manager,
    address _auditor,
    address _usdc,
    address _cepholia
) Ownable(msg.sender) {
    // -------------------- Validaciones --------------------
    if (_oracleAddress == address(0)) revert InvalidToken(_oracleAddress);
    if (_admin == address(0) || _manager == address(0)) revert Unauthorized();

    // -------------------- Oráculo --------------------
    priceFeed = AggregatorV3Interface(_oracleAddress);

    // -------------------- Roles --------------------
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); // rol raíz
    _grantRole(ADMIN_ROLE, _admin);
    _grantRole(MANAGER_ROLE, _manager);
    if (_auditor != address(0)) _grantRole(AUDITOR_ROLE, _auditor);

    // -------------------- Límites iniciales --------------------
    bankCapUSD = 100_000 * 10 ** USD_DECIMALS;     // 100.000 USD
    withdrawLimitUSD = 5_000 * 10 ** USD_DECIMALS; // 5.000 USD
    totalDepositsUSD = 0;

    // -------------------- Tokens soportados --------------------
    supportedTokens[address(0)] = true; // ETH nativo
    if (_usdc != address(0)) supportedTokens[_usdc] = true;
    if (_cepholia != address(0)) supportedTokens[_cepholia] = true;

    emit SupportedTokenAdded(address(0));
    if (_usdc != address(0)) emit SupportedTokenAdded(_usdc);
    if (_cepholia != address(0)) emit SupportedTokenAdded(_cepholia);

    // -------------------- Evento de inicialización --------------------
    address[] memory tokens = new address[](3);
    tokens[0] = address(0);
    tokens[1] = _usdc;
    tokens[2] = _cepholia;

    emit ContractInitialized(msg.sender, _oracleAddress, bankCapUSD, withdrawLimitUSD, tokens);
}


// =============================================================
// 7. DEPÓSITO Y RETIRO
// =============================================================

    /**
     * @notice Permite depositar ETH o tokens ERC-20 soportados.
     * @dev Aplica patrón Checks-Effects-Interactions y protección nonReentrant.
     *      Convierte el monto a USD usando el oráculo y valida bankCapUSD.
     * @param token Dirección del token a depositar (address(0) para ETH).
     * @param amount Monto a depositar (en wei o en unidades del token ERC-20).
     */
    function deposit(address token, uint256 amount)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (token == address(0)) {
            // ---- ETH nativo ----
            if (msg.value == 0) revert ZeroAmount();
            amount = msg.value;
        } else {
            // ---- ERC-20 ----
            if (amount == 0) revert ZeroAmount();
            if (!supportedTokens[token]) revert InvalidToken(token);
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        // ---- Conversión a USD y verificación de límite ----
        uint256 valueUSD = convertToUSD(token, amount);
        if (totalDepositsUSD + valueUSD > bankCapUSD)
            revert BankCapExceeded(bankCapUSD, totalDepositsUSD + valueUSD);

        // ---- Actualización de balances ----
        balances[msg.sender][token] += amount;
        totalDepositsUSD += valueUSD;

        emit Deposit(msg.sender, token, amount);
    }

    /**
     * @notice Permite retirar ETH o tokens ERC-20 previamente depositados.
     * @dev Aplica Checks-Effects-Interactions, protección nonReentrant y límites individuales.
     * @param token Dirección del token a retirar (address(0) para ETH).
     * @param amount Monto a retirar (en wei o unidades del token ERC-20).
     */
    function withdraw(address token, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        uint256 userBalance = balances[msg.sender][token];
        if (userBalance < amount)
            revert InsufficientBalance(msg.sender, amount, userBalance);

        // ---- Conversión a USD y verificación de límite de retiro ----
        uint256 valueUSD = convertToUSD(token, amount);
        if (valueUSD > withdrawLimitUSD)
            revert BankCapExceeded(withdrawLimitUSD, valueUSD);

        // ---- Effects ----
        balances[msg.sender][token] -= amount;
        totalDepositsUSD -= valueUSD;

        // ---- Interactions ----
        if (token == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit Withdraw(msg.sender, token, amount);
    }

// =============================================================
// 8. ADMINISTRACIÓN Y CONFIGURACIÓN
// =============================================================

    /**
     * @notice Actualiza el límite global del banco (capacidad total en USD).
     * @dev Solo accesible para el OWNER o ADMIN.
     *      Emite un evento con los valores anterior y nuevo.
     * @param newCap Nuevo valor del límite global expresado en USD (con 6 decimales).
     */
    function setBankCap(uint256 newCap) external onlyAdmin whenNotPaused {
        if (newCap == 0) revert ZeroAmount();
        uint256 oldCap = bankCapUSD;
        bankCapUSD = newCap;

        emit BankCapUpdated(oldCap, newCap);
    }

    /**
     * @notice Actualiza el límite máximo de retiro individual por usuario (en USD).
     * @dev Solo accesible para el OWNER o ADMIN.
     * @param newLimit Nuevo valor del límite individual (con 6 decimales).
     */
    function setWithdrawLimit(uint256 newLimit) external onlyAdmin whenNotPaused {
        if (newLimit == 0) revert ZeroAmount();
        withdrawLimitUSD = newLimit;
    }

    /**
     * @notice Añade un nuevo token ERC-20 permitido en el banco.
     * @dev Solo accesible para el OWNER o ADMIN.
     *      Verifica que no sea address(0) y que no esté ya habilitado.
     * @param token Dirección del contrato ERC-20 que se desea permitir.
     */
    function addSupportedToken(address token) external onlyAdmin whenNotPaused {
        if (token == address(0)) revert InvalidToken(token);
        if (supportedTokens[token]) revert InvalidToken(token); // ya existe
        supportedTokens[token] = true;

        emit SupportedTokenAdded(token);
    }

    /**
     * @notice Remueve o deshabilita un token previamente permitido.
     * @dev Solo accesible para el OWNER o ADMIN.
     *      No elimina los saldos existentes, pero bloquea nuevos depósitos.
     * @param token Dirección del token que se desea deshabilitar.
     */
    function removeSupportedToken(address token) external onlyAdmin whenNotPaused {
        if (token == address(0)) revert InvalidToken(token);
        if (!supportedTokens[token]) revert InvalidToken(token); // no estaba activo
        supportedTokens[token] = false;

        emit SupportedTokenRemoved(token);
    }

    /**
     * @notice Consulta si un token está habilitado para operar.
     * @param token Dirección del token a consultar.
     * @return true si está permitido, false en caso contrario.
     */
    function isTokenSupported(address token) public view returns (bool) {
        return supportedTokens[token];
    }

// =============================================================
// 9. ORÁCULO Y CONVERSIÓN DE VALORES
// =============================================================

    /**
     * @notice Consulta el último precio ETH/USD desde el oráculo Chainlink.
     * @dev Devuelve el precio con 8 decimales según el feed estándar de Chainlink.
     * @return price Precio actual de 1 ETH en USD (ej: 2500.00000000)
     */
    function getLatestPrice() public view returns (uint256 price) {
        (
            , 
            int256 answer,
            ,
            ,
            
        ) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid oracle price");
        price = uint256(answer);
    }

    /**
     * @notice Convierte un monto en ETH o ERC-20 al valor equivalente en USD.
     * @dev Utiliza el precio actual del oráculo ETH/USD y normaliza decimales.
     * @param token Dirección del token (address(0) si es ETH).
     * @param amount Monto en wei o unidades del token.
     * @return valueUSD Valor equivalente en USD con 6 decimales.
     */
    function convertToUSD(address token, uint256 amount) public view returns (uint256 valueUSD) {
        if (amount == 0) return 0;

        // Caso 1: ETH nativo
        if (token == address(0)) {
            uint256 ethPrice = getLatestPrice(); // ETH/USD con 8 decimales
            // amount (wei → ETH) * precio / 1e(18-8) → resultado en USD * 1e6
            // => (amount * ethPrice * 10^(USD_DECIMALS)) / 1e(18)
            valueUSD = (amount * ethPrice * (10 ** USD_DECIMALS)) / 1e26;
            // 1e26 = 1e18 (wei) * 1e8 (decimales del oráculo)
        } 
        // Caso 2: ERC-20
        else {
            if (!supportedTokens[token]) revert InvalidToken(token);
            uint8 tokenDecimals = IERC20Metadata(token).decimals();
            // Normalización a USD_DECIMALS (6)
            // Supongamos 1 token = 1 USD (por simplicidad, sin oráculo propio)
            if (tokenDecimals > USD_DECIMALS)
                valueUSD = amount / (10 ** (tokenDecimals - USD_DECIMALS));
            else
                valueUSD = amount * (10 ** (USD_DECIMALS - tokenDecimals));
        }
    }

// =============================================================
// 10. PAUSABLE Y EMERGENCIAS
// =============================================================

    /**
     * @notice Pausa todas las operaciones críticas del contrato.
     * @dev Solo puede ser ejecutada por el OWNER o un ADMIN autorizado.
     *      Las funciones con el modificador `whenNotPaused` quedarán bloqueadas.
     */
    function pause() external onlyAdmin whenNotPaused {
        _pause();
        emit Paused(msg.sender);
    }

    /**
     * @notice Reanuda las operaciones del contrato tras una pausa.
     * @dev Solo puede ser ejecutada por el OWNER o un ADMIN autorizado.
     */
    function unpause() external onlyAdmin whenPaused {
        _unpause();
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Permite al ADMIN o OWNER ejecutar retiros de emergencia si fuera necesario.
     * @dev Solo se habilita cuando el contrato está pausado.
     *      Sirve para devolver fondos en situaciones críticas sin permitir nuevas operaciones.
     * @param token Dirección del token a recuperar (address(0) para ETH).
     * @param recipient Dirección que recibirá los fondos.
     * @param amount Monto a transferir.
     */
    function emergencyWithdraw(address token, address recipient, uint256 amount)
        external
        onlyAdmin
        whenPaused
        nonReentrant
    {
        if (recipient == address(0)) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();

        if (token == address(0)) {
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }

        emit Withdraw(recipient, token, amount);
    }

// =============================================================
// 11. FUNCIONES AUXILIARES INTERNAS
// =============================================================

    /**
     * @notice Valida si un token está soportado.
     * @dev Devuelve true si está habilitado, o revierte con InvalidToken en caso contrario.
     * @param token Dirección del token a verificar.
     */
    function _validateSupportedToken(address token) internal view {
        if (!supportedTokens[token]) revert InvalidToken(token);
    }

    /**
     * @notice Obtiene la cantidad de decimales de un token ERC-20.
     * @dev Usa la interfaz IERC20Metadata para acceder a decimals().
     * @param token Dirección del token.
     * @return decimals Número de decimales del token.
     */
    function _getTokenDecimals(address token) internal view returns (uint8 decimals) {
        decimals = IERC20Metadata(token).decimals();
    }

    /**
     * @notice Calcula la diferencia porcentual entre dos valores en base 10000 (basis points).
     * @dev Ejemplo: 100 puntos base = 1%.
     * @param value Valor principal.
     * @param percentage Porcentaje en basis points (ej. 250 = 2.5%).
     * @return result Valor final luego de aplicar el porcentaje.
     */
    function _applyPercentage(uint256 value, uint256 percentage) internal pure returns (uint256 result) {
        result = (value * percentage) / 10_000;
    }

    /**
     * @notice Función de utilidad para obtener el balance total del contrato (ETH + tokens).
     * @dev Sirve para monitoreo o auditoría.
     * @param token Dirección del token (address(0) para ETH).
     * @return balance Balance del contrato en ese token.
     */
    function _contractBalance(address token) internal view returns (uint256 balance) {
        if (token == address(0)) {
            balance = address(this).balance;
        } else {
            balance = IERC20(token).balanceOf(address(this));
        }
    }

    /**
     * @notice Verifica si una cuenta tiene el rol especificado o es el OWNER.
     * @dev Simplifica validaciones internas de acceso.
     * @param role Rol que se desea verificar.
     * @param account Dirección a verificar.
     * @return hasAccess true si tiene permisos, false de lo contrario.
     */
    function _hasAccess(bytes32 role, address account) internal view returns (bool hasAccess) {
        hasAccess = (hasRole(role, account) || account == owner());
    }

    /**
     * @notice Suma segura con validación de overflow.
     * @dev Sirve para cálculos de totales con control extra de integridad.
     */
    function _safeAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "Addition overflow");
        return c;
    }

    /**
     * @notice Resta segura con validación de underflow.
     * @dev Sirve para balances o límites que no pueden ser negativos.
     */
    function _safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "Subtraction underflow");
        return a - b;
    }

    // =============================================================
    // 12. FUNCIONES DE SOPORTE Y FALLBACK
    // =============================================================

    /**
     * @notice Función especial que permite recibir ETH directamente.
     * @dev Se ejecuta cuando el contrato recibe ETH sin datos (msg.data vacía).
     *      Registra el depósito como si fuera un `deposit(address(0), msg.value)`.
     */
    receive() external payable {
        if (msg.value == 0) revert ZeroAmount();
        if (!supportedTokens[address(0)]) revert InvalidToken(address(0));

        balances[msg.sender][address(0)] += msg.value;

        uint256 valueUSD = convertToUSD(address(0), msg.value);
        totalDepositsUSD += valueUSD;

        emit Deposit(msg.sender, address(0), msg.value);
    }

    /**
     * @notice Función de respaldo para llamadas con datos no reconocidos.
     * @dev Rechaza cualquier intento de llamada a funciones inexistentes.
     */
    fallback() external payable {
        revert("Function does not exist");
    }

}
