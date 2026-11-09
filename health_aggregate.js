const TARGETS = [
    { name: "identity-service", url: "http://identity-service:8002/health/" },
    { name: "social-service", url: "http://social-service:8000/health/" },
    { name: "search-service", url: "http://search-service:8001/health/" },
    { name: "search-bff-service", url: "http://search-bff-service:8002/health" },
    { name: "predictive-service", url: "http://predictive-service:8003/health" },
    { name: "rag-service", url: "http://rag-service:8181/health" },
    { name: "governance-service", url: "http://governance-service:8005/health" },
    { name: "analytics-service", url: "http://analytics-service:8006/health" },
    { name: "ethical-recommender-service", url: "http://ethical-recommender-service:8007/health" },
    { name: "centinela-front", url: "http://centinela-front:80/health" },
];

async function fetchHealth(target) {
    try {
        const reply = await ngx.fetch(target.url, { headers: { Accept: "application/json" } });
        const body = await reply.json();
        // Services that do not use the platform health format (no `groups`), e.g.
        // ethical-recommender-service ({status: "ok", ...}), are mapped to it so one
        // odd payload cannot break the whole aggregate.
        if (!body || !Array.isArray(body.groups)) {
            const up = reply.ok && (!body || body.status === undefined || body.status === "ok");
            return {
                server_name: target.name,
                global_status: up ? "Online" : "Degraded",
                groups: [
                    {
                        group_name: target.name,
                        group_status: up ? "Operativo" : "Degradado",
                        services: [{ name: target.name, status: up ? "ok" : "error" }],
                    },
                ],
            };
        }
        return body;
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

// governance-service and analytics-service both report their group as
// "Service runtime", so the aggregate showed two indistinguishable entries. When a
// group name appears more than once, qualify every occurrence with the service
// that reported it.
function uniqueGroupNames(entries) {
    const counts = {};
    for (let i = 0; i < entries.length; i++) {
        const name = entries[i].group.group_name;
        counts[name] = (counts[name] || 0) + 1;
    }

    return entries.map(function (entry) {
        const group = entry.group;
        if (counts[group.group_name] < 2) {
            return group;
        }
        return Object.assign({}, group, {
            group_name: group.group_name + " (" + entry.server + ")",
        });
    });
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

    const entries = [];

    for (let i = 0; i < results.length; i++) {
        const body = results[i];
        for (let j = 0; j < body.groups.length; j++) {
            entries.push({
                server: body.server_name || TARGETS[i].name,
                group: body.groups[j],
            });
        }
        if (body.global_status === "Offline") anyOffline = true;
        if (body.global_status === "Degraded") anyDegraded = true;
    }

    const unique = uniqueGroupNames(entries);
    for (let i = 0; i < unique.length; i++) {
        groups.push(unique[i]);
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
