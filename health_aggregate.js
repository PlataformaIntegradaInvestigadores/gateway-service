const TARGETS = [
    { name: "identity-service", url: "http://identity-service:8002/health/" },
    { name: "social-service", url: "http://social-service:8000/health/" },
    { name: "search-service", url: "http://search-service:8001/health/" },
    { name: "search-bff-service", url: "http://search-bff-service:8002/health" },
    { name: "predictive-service", url: "http://predictive-service:8003/health" },
    { name: "rag-service", url: "http://rag-service:8181/health" },
    { name: "centinela-front", url: "http://centinela-front:80/health" },
];

async function fetchHealth(target) {
    try {
        const reply = await ngx.fetch(target.url, { headers: { Accept: "application/json" } });
        return await reply.json();
    } catch (e) {
        return {
            server_name: target.name,
            global_status: "Offline",
            groups: [
                {
                    group_name: target.name,
                    group_status: "Caído",
                    services: [{ name: target.name, status: "error" }],
                },
            ],
        };
    }
}

async function healthAll(r) {
    const results = await Promise.all(TARGETS.map(fetchHealth));

    const groups = [
        {
            group_name: "Middleware / Auth",
            group_status: "Operativo",
            services: [{ name: "proxy", status: "ok" }],
        },
    ];

    let anyOffline = false;
    let anyDegraded = false;

    for (let i = 0; i < results.length; i++) {
        const body = results[i];
        for (let j = 0; j < body.groups.length; j++) {
            groups.push(body.groups[j]);
        }
        if (body.global_status === "Offline") anyOffline = true;
        if (body.global_status === "Degraded") anyDegraded = true;
    }

    let global_status = "Online";
    if (anyOffline) {
        global_status = "Offline";
    } else if (anyDegraded) {
        global_status = "Degraded";
    }

    const payload = {
        server_name: "Centinela",
        ip_address: r.variables.server_addr,
        global_status: global_status,
        groups: groups,
    };

    r.headersOut["Content-Type"] = "application/json";
    r.return(200, JSON.stringify(payload));
}

export default { healthAll };
