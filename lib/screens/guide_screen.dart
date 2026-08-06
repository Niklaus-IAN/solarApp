import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          
          const Text(
            'Follow these steps for a safe and efficient solar installation.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
          
          const SizedBox(height: 16),
          
          _buildGuideStep(1, 'Site Assessment', Icons.location_on, AppTheme.accentBlue, [
            'Choose a location that receives direct sunlight for most of the day (minimum 5 hours).',
            'Check for shading obstructions — trees, buildings, antennas, water tanks.',
            'The roof or mounting surface must be structurally strong enough to hold the panels.',
            'Identify where the battery bank and inverter will be placed (cool, dry, ventilated area).',
          ]),
          
          _buildGuideStep(2, 'Panel Orientation & Tilt', Icons.explore, AppTheme.accentGreen, [
            'In Nigeria (Northern Hemisphere), panels should face south for maximum sun exposure.',
            'Tilt angle should be approximately equal to your latitude — for Lagos this is about 6-7°.',
            'A slight tilt of at least 10° is recommended even in equatorial areas to allow rainwater to wash off dust.',
            'Avoid mounting panels completely flat — water pooling causes long-term damage.',
          ]),
          
          _buildGuideStep(3, 'Panel Mounting & Ventilation', Icons.grid_view, AppTheme.accentOrange, [
            'IMPORTANT: Leave at least 10-15 cm air gap between the panel and the roof surface.',
            'Panels mounted flush against roofing sheets with no ventilation run 12-15°C hotter.',
            'This temperature increase reduces power output by approximately 5-6%.',
            'Use a raised frame or mounting rails to ensure airflow beneath the panels.',
            'Secure panels against wind — use proper mounting brackets and bolts, not wire ties.',
          ]),
          
          _buildGuideStep(4, 'Electrical Wiring', Icons.cable, AppTheme.accentYellow, [
            'Use cables sized according to the maximum current and cable run length.',
            'Keep cable runs as short as possible to minimise voltage drop.',
            'Use MC4 connectors for panel-to-panel connections (weather-sealed).',
            'All connections must be tight — loose connections cause heat buildup and power loss.',
            'Install appropriate fuses or circuit breakers between panels and charge controller.',
            'Connect panels to charge controller BEFORE connecting battery to controller.',
          ]),
          
          _buildGuideStep(5, 'Battery Installation', Icons.battery_charging_full, AppTheme.accentBlue, [
            'Place batteries in a cool, dry, well-ventilated location — not in direct sunlight.',
            'Lead-acid batteries produce hydrogen gas during charging — ensure ventilation.',
            'All batteries in a parallel bank must be identical — same brand, capacity, and age.',
            'Use short, thick cables for battery interconnections to minimise losses.',
            'Install a battery isolation switch for safety during maintenance.',
          ]),
          
          _buildGuideStep(6, 'System Commissioning', Icons.check_circle, AppTheme.accentGreen, [
            'With panels covered (no sunlight), connect the charge controller to the battery first.',
            'Then uncover panels and verify the charge controller shows charging status.',
            'Check all voltage readings with a multimeter against expected values.',
            'Connect the inverter and test with a small load before connecting all appliances.',
            'Install the Solar OBD diagnostic unit and verify readings match your multimeter.',
            'Run the system for 24 hours and check the Performance History for any anomalies.',
          ]),
          
          const SizedBox(height: 20),
          
          // Safety warning
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.accentRed.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.accentRed.withOpacity(0.25)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.warning_amber, color: AppTheme.accentRed, size: 20),
                    SizedBox(width: 8),
                    Text('Safety Notice', style: TextStyle(color: AppTheme.accentRed, fontWeight: FontWeight.w700, fontSize: 15)),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  'Solar panels produce electricity when exposed to light. Always cover panels with opaque material before working on electrical connections. If you are not confident working with electrical systems, hire a qualified technician.',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.5),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 20),

          // Plain-English glossary for the terms used across the app's
          // sizing results (e.g. "2 strings of 3 in series").
          _buildGlossary(),

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildGlossary() {
    // (term, plain-English meaning). Kept in the order a first-time installer
    // meets them: wiring words first, then the numbers on the results screen.
    const entries = <(String, String)>[
      (
        'Series',
        'Panels (or batteries) wired end-to-end — positive of one to the '
            'negative of the next. Series adds up VOLTAGE. Three 32.5 V panels '
            'in series make about 97.5 V.'
      ),
      (
        'Parallel',
        'Separate lines wired side-by-side — all the positives joined, all the '
            'negatives joined. Parallel adds up CURRENT (amps); the voltage '
            'stays the same.'
      ),
      (
        'String',
        'One line of panels wired in series. So "2 strings of 3 in series" '
            'means two separate lines, each made of 3 panels, and the two '
            'lines are then joined in parallel at the controller.'
      ),
      (
        'Wp (Watt-peak)',
        'A panel\'s power under full test sunlight. "1800 Wp" is the array\'s '
            'rated size on paper — real output in the field is a little lower.'
      ),
      (
        'PSH (Peak Sun Hours)',
        'How many hours of full-strength sun a place gets per day. Lagos gets '
            'about 3.8 in its worst month. It sets how much energy your panels '
            'can make each day.'
      ),
      (
        'Vmpp',
        'The voltage a panel produces at its best working point. A string\'s '
            'Vmpp must stay above the battery charging voltage, or the '
            'controller cannot charge.'
      ),
      (
        'Voc (cold)',
        'A panel\'s highest possible voltage — measured open-circuit on a cold '
            'morning. The charge controller must be rated ABOVE this figure or '
            'it can be damaged.'
      ),
      (
        'Isc',
        'A panel\'s short-circuit current — the most amps it can push. Used to '
            'size the fuses and the PV cable.'
      ),
      (
        'MPPT vs PWM',
        'Two charge-controller types. MPPT turns spare panel voltage into extra '
            'charging current (efficient, allows long strings). PWM is simpler '
            'and cheaper but wastes any voltage above the battery.'
      ),
      (
        'Ah (Amp-hour)',
        'Battery capacity. A 200 Ah battery can give roughly 200 A for 1 hour, '
            'or 10 A for 20 hours.'
      ),
      (
        'DoD (Depth of Discharge)',
        'How much of the battery you can safely use. Lithium about 80%, '
            'lead-acid about 50%. Draining deeper than this shortens its life.'
      ),
      (
        'Autonomy (days)',
        'How many sunless days the battery alone can run your load with no '
            'charging. Usually 2 to 3 days.'
      ),
      (
        'Surge',
        'The brief spike of power a motor (fridge, pump, AC) needs to start — '
            'often about 3x its running watts. The inverter must be able to '
            'supply this spike.'
      ),
      (
        'Voltage drop',
        'Power lost as heat in long or thin cables. The design keeps it under '
            '4% by choosing thick-enough cable.'
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.menu_book, color: AppTheme.accentBlue, size: 20),
              SizedBox(width: 8),
              Text('Glossary — Terms Explained',
                  style: TextStyle(
                      color: AppTheme.accentBlue,
                      fontWeight: FontWeight.w700,
                      fontSize: 15)),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Plain-English meaning of the words used on the sizing results '
            'screen.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 14),
          ...entries.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.$1,
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5)),
                    const SizedBox(height: 3),
                    Text(e.$2,
                        style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12.5,
                            height: 1.5)),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildGuideStep(int step, String title, IconData icon, Color color, List<String> points) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    '$step',
                    style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 15)),
            ],
          ),
          const SizedBox(height: 12),
          ...points.map((point) => Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  width: 5, height: 5,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.5),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    point,
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.5),
                  ),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
}
